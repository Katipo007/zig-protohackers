const std = @import("std");
const common = @import("common");
const settings = common.settings;
const log = std.log.scoped(.@"problem-0");

pub fn main() !void {
    defer log.info("Exit", .{});
    log.info("Start", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const result = gpa.deinit();
        std.debug.assert(result == .ok);
    }

    const allocator = gpa.allocator();

    const host_address = try std.net.Address.parseIp(settings.default_address, settings.default_port);
    var server = try host_address.listen(.{});
    defer server.deinit();

    log.info("Server listening on '{}'", .{server.listen_address});

    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{
        .allocator = allocator,
        .n_jobs = settings.default_num_jobs,
    });
    defer thread_pool.deinit();

    const running = true;
    while (running) {
        log.debug("Waiting for connection...", .{});
        if (server.accept()) |new_connection| {
            errdefer new_connection.stream.close();
            try thread_pool.spawn(handle_connection, .{new_connection});
        } else |accept_error| {
            switch (accept_error) {
                else => |err| {
                    log.err("Error accepting connection: {}", .{err});
                },
            }
        }
    }

    return;
}

fn handle_connection(connection: std.net.Server.Connection) void {
    defer connection.stream.close();
    defer log.info("Finished connection for '{}'", .{connection.address});

    log.info("Accepted connection from '{}'", .{connection.address});

    const max_message_size = 1024 * 4;
    var read_buffer: [max_message_size]u8 = undefined;

    while (true) {
        const num_bytes_read = connection.stream.readAll(read_buffer[0..]) catch |err| {
            log.err("Failed to read message from '{}'. Error = {}", .{ connection.address, err });
            return;
        };

        const message = read_buffer[0..num_bytes_read];
        if (message.len == 0) {
            break;
        }

        log.debug("Read message of '{}' bytes from '{}'", .{ message.len, connection.address });

        connection.stream.writeAll(message) catch |err| {
            log.err("Failed to write message back to '{}'. Error = {}", .{ connection.address, err });
            return;
        };

        log.debug("Sent message back to '{}'", .{connection.address});
    }
}
