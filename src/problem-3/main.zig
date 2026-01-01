const max_username_length = 32;
const max_message_length = 1024;
const message_buffer_length = max_message_length + max_username_length + 8;

pub fn main() !void {
    defer log.info("[Main] Exit", .{});
    log.info("[Main] Start", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const result = gpa.deinit();
        std.debug.assert(result == .ok);
    }
    const allocator = gpa.allocator();

    var gpio = std.Io.Threaded.init(allocator);
    defer gpio.deinit();
    const io = gpio.io();

    var room: Room = .init(allocator);
    defer room.deinit(io);

    const host_address = try std.Io.net.IpAddress.parse(config.listen_address, config.listen_port);
    var server = try host_address.listen(io, .{
        .mode = .stream,
        .protocol = .tcp,
        .reuse_address = true,
    });
    defer server.deinit(io);

    log.info("[Main] Server listening on '{f}'", .{host_address});

    var group = std.Io.Group.init;
    defer group.cancel(io);

    var context = Context{
        .gpa = allocator,
        .io = io,
        .room = &room,
    };

    const running: bool = true;
    log.debug("Waiting for connection...", .{});
    while (running) {
        const stream = try server.accept(io);
        try group.concurrent(io, handle_connection, .{ &context, stream });
    }

    return;
}

const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    room: *Room,
};

const Room = struct {
    const Member = struct {
        username: []const u8,
        conn_mutex: *std.Io.Mutex,
        conn_writer: *std.Io.Writer,
    };
    members_mutex: std.Io.Mutex = .init,
    members_allocator: std.mem.Allocator,
    members: std.ArrayListUnmanaged(*const Member) = .{},

    fn init(allocator: std.mem.Allocator) Room {
        return .{
            .members_allocator = allocator,
        };
    }

    fn deinit(self: *Room, io: std.Io) void {
        self.members_mutex.lockUncancelable(io);
        defer self.members_mutex.unlock(io);

        self.members.deinit(self.members_allocator);
        self.* = undefined;
    }

    fn on_member_joined(self: *Room, io: std.Io, member: *const Member) !void {
        log.info("'{s}' joined the room", .{member.username});

        try self.members_mutex.lock(io);
        defer self.members_mutex.unlock(io);

        try self.members.ensureUnusedCapacity(self.members_allocator, 1);

        {
            try member.conn_mutex.lock(io);
            defer member.conn_mutex.unlock(io);

            try member.conn_writer.writeAll("* The room contains: ");
            for (self.members.items, 0..) |other_member, idx| {
                try member.conn_writer.writeAll(other_member.username);
                if (idx != 0)
                    try member.conn_writer.writeAll(", ");
            }
            try member.conn_writer.writeByte('\n');
            try member.conn_writer.flush();
        }

        self.members.appendAssumeCapacity(member);

        var announce_message_buff: [message_buffer_length]u8 = undefined;
        try self.send_message_nonlocking(io, member, try std.fmt.bufPrint(&announce_message_buff, "* {s} has entered the room\n", .{member.username}));
    }

    fn on_member_left(self: *Room, io: std.Io, member: *const Member) !void {
        log.info("'{s}' left the room", .{member.username});

        try self.members_mutex.lock(io);
        defer self.members_mutex.unlock(io);

        for (self.members.items, 0..) |entry, idx| {
            if (entry == member) {
                _ = self.members.swapRemove(idx);
                break;
            }
        }

        var announce_message_buff: [message_buffer_length]u8 = undefined;
        try self.send_message_nonlocking(io, null, try std.fmt.bufPrint(&announce_message_buff, "* {s} has left the room\n", .{member.username}));
    }

    fn send_message(self: *Room, io: std.Io, sender: ?*const Member, message: []const u8) !void {
        try self.members_mutex.lock(io);
        defer self.members_mutex.unlock(io);

        try send_message_nonlocking(self, io, sender, message);
    }

    fn send_message_nonlocking(self: *Room, io: std.Io, sender: ?*const Member, message: []const u8) !void {
        var num_sent: usize = 0;
        defer log.info("Broadcasted message '{s}' to {d} members", .{ message, num_sent });

        for (self.members.items) |receiver| {
            if (receiver == sender)
                continue;

            receiver.conn_mutex.lock(io) catch continue;
            defer receiver.conn_mutex.unlock(io);

            receiver.conn_writer.writeAll(message) catch {
                log.err("Failed to send a message to '{s}'", .{receiver.username});
                continue;
            };
            receiver.conn_writer.flush() catch {
                log.err("Failed to send a message to '{s}'", .{receiver.username});
                continue;
            };
            num_sent += 1;
        }
    }
};

fn handle_connection(context: *Context, stream: std.Io.net.Stream) void {
    const id = stream.socket.address;

    log.debug("[{f}] Connection accepted", .{id});
    defer log.debug("[{f}] Connection closed", .{id});

    const io = context.io;
    defer stream.close(io);

    var recv_buffer: [message_buffer_length]u8 = undefined;
    var send_buffer: [message_buffer_length]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buffer);
    var conn_writer = stream.writer(io, &send_buffer);
    var conn_mutex = std.Io.Mutex.init;

    conn_writer.interface.writeAll("Welcome to budgetchat! Please enter a username. (1-32 alphanumeric ASCII characters)\n") catch return;
    conn_writer.interface.flush() catch return;

    var username_buffer: [max_message_length]u8 = undefined;
    var username_writer = std.Io.Writer.fixed(&username_buffer);
    const username_len = conn_reader.interface.streamDelimiterLimit(&username_writer, '\n', .limited(username_buffer.len)) catch return;
    if (username_len < 2 or username_len > max_username_length) {
        conn_writer.interface.writeAll("Your username must be between 1 and 32 characters long.\n") catch return;
        conn_writer.interface.flush() catch return;
        return;
    }

    const username = username_buffer[0..username_len];
    for (username) |c| {
        if (!std.ascii.isAlphanumeric(c)) {
            conn_writer.interface.writeAll("Your username must only contain alphanumeric ASCII characters. (A-Z, a-z, 0-9)\n") catch return;
            conn_writer.interface.flush() catch return;
            return;
        }
    }

    log.info("[{f}] Username set to '{s}'", .{ id, username });

    const room = context.room;

    const room_member: Room.Member = .{
        .conn_mutex = &conn_mutex,
        .conn_writer = &conn_writer.interface,
        .username = username,
    };

    room.on_member_joined(io, &room_member) catch |join_err| {
        std.log.err("[{f}] Failed to join room. Error = {}", .{ id, join_err });
        return;
    };
    defer {
        room.on_member_left(io, &room_member) catch |leave_err| {
            std.log.err("[{f}] Error encountered while leaving the room: {}", .{ id, leave_err });
        };
    }

    while (true) {
        const raw_message = conn_reader.interface.takeDelimiter('\n') catch |read_err| switch (read_err) {
            error.StreamTooLong => {
                log.err("[{f}] OOM receiving message", .{id});
                return;
            },
            else => {
                log.err("[{f}] Failed to read message. Error = {?}", .{ id, conn_reader.err });
                return;
            },
        } orelse return;
        if (raw_message.len == 0)
            continue;

        log.debug("[{f}] '{s}'", .{ id, raw_message });

        var sent_message_buffer: [message_buffer_length]u8 = undefined;
        const broadcasted_message = std.fmt.bufPrint(&sent_message_buffer, "[{s}] {s}\n", .{ username, raw_message }) catch {
            conn_mutex.lock(io) catch return;
            defer conn_mutex.unlock(io);
            conn_writer.interface.writeAll("* Message was too long") catch return;
            conn_writer.interface.flush() catch return;
            continue;
        };
        room.send_message(io, &room_member, broadcasted_message) catch |send_err| {
            log.err("[{f}] Failed to send chat message. Error = {}", .{ id, send_err });
            continue;
        };
    }
}

const std = @import("std");
const common = @import("common");
const config = common.config;
const log = std.log.scoped(.@"problem-3");
