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
};

const Record = struct {
    timestamp: i32,
    price: i32,

    fn compare_timestamp(_: void, lhs: i32, rhs: @This()) std.math.Order {
        return std.math.order(lhs, rhs.timestamp);
    }
};

const Command = enum(u8) {
    insert = 'I',
    query = 'Q',
};

fn handle_connection(context: *Context, stream: std.Io.net.Stream) void {
    const id = stream.socket.address;

    log.debug("[{f}] Connection accepted", .{id});
    defer log.debug("[{f}] Connection closed", .{id});

    const io = context.io;
    defer stream.close(io);

    var gpa = std.heap.stackFallback(4068, context.gpa);
    const allocator = gpa.get();

    var stats: struct {
        num_insert_commands: usize = 0,
        num_query_commands: usize = 0,
    } = .{};
    defer log.debug("[{f}] Stats = {}", .{ id, stats });

    var records: std.ArrayList(Record) = .{};
    defer {
        log.debug("[{f}] Total num records = {d}", .{ id, records.items.len });
        records.deinit(allocator);
    }

    var recv_buffer: [1024 * 1024]u8 = undefined;
    var send_buffer: [128]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buffer);
    var conn_writer = stream.writer(io, &send_buffer);
    while (true) {
        const command_id = conn_reader.interface.takeEnum(Command, .big) catch |read_err| {
            if (read_err != error.EndOfStream) {
                log.err("[{f}] Failed to read message. Error = {?}", .{ id, conn_reader.err });
            }
            return;
        };

        var request_timer = std.time.Timer.start() catch @panic("Failed to start timer");
        defer log.debug("[{f}] request took {d}ms", .{ id, @divTrunc(request_timer.read(), std.time.ns_per_ms) });

        log.debug("[{f}] Received command: {}", .{ id, command_id });

        switch (command_id) {
            .insert => {
                stats.num_insert_commands += 1;
                const command = conn_reader.interface.takeStruct(extern struct { timestamp: i32, price: i32 }, .big) catch |read_err| {
                    if (read_err != error.EndOfStream) {
                        log.err("[{f}] Failed to read insert command. Error = {?}", .{ id, conn_reader.err });
                    }
                    return;
                };

                const target_index = common.utility.lower_bound(Record, command.timestamp, records.items, {}, Record.compare_timestamp);
                if (target_index < records.items.len and records.items[target_index].timestamp == command.timestamp) {
                    // Value already exists, by protocol definition this is undefined behavior.
                    // We choose to overwrite the value
                    var record = &records.items[target_index];
                    record.price = command.price;
                } else {
                    records.insert(allocator, target_index, Record{ .timestamp = command.timestamp, .price = command.price }) catch |err| {
                        log.err("[{f}] Error recording price. Error = {}", .{ id, err });
                        return;
                    };
                }

                log.debug("[{f}] Inserted record. Timestamp = {}, Price = {}", .{ id, command.timestamp, command.price });
            },
            .query => {
                stats.num_query_commands += 1;
                const command = conn_reader.interface.takeStruct(extern struct { min_timestamp: i32, max_timestamp: i32 }, .big) catch |read_err| {
                    if (read_err != error.EndOfStream) {
                        log.err("[{f}] Failed to read query command. Error = {?}", .{ id, conn_reader.err });
                    }
                    return;
                };

                var sum: i128 = 0;
                var num_entries: usize = 0;

                if (command.min_timestamp <= command.max_timestamp) {
                    const lower_bound_index = common.utility.lower_bound(Record, command.min_timestamp, records.items, {}, Record.compare_timestamp);
                    const upper_bound_index = common.utility.upper_bound(Record, command.max_timestamp, records.items, {}, Record.compare_timestamp);
                    if (lower_bound_index < records.items.len and upper_bound_index <= records.items.len) {
                        for (lower_bound_index..upper_bound_index) |idx| {
                            sum += records.items[idx].price;
                            num_entries += 1;
                        }
                    }
                }

                const mean_price = bk: {
                    if (num_entries > 0) {
                        break :bk @divTrunc(sum, num_entries);
                    }

                    break :bk 0;
                };

                log.debug("[{f}] Price query. MinTimestamp = {}, MaxTimestamp = {}, Mean = {}", .{ id, command.min_timestamp, command.max_timestamp, mean_price });
                conn_writer.interface.writeInt(i32, @intCast(mean_price), .big) catch {
                    log.err("[{f}] Failed to write query response. Error = {?}", .{ id, conn_writer.err });
                };
                conn_writer.interface.flush() catch {
                    log.err("[{f}] Failed to flush query response. Error = {?}", .{ id, conn_writer.err });
                };
            },
        }
    }
}

const std = @import("std");
const common = @import("common");
const config = common.config;
const log = std.log.scoped(.@"problem-2");
