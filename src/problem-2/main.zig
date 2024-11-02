const std = @import("std");
const common = @import("common");
const settings = common.settings;
const log = std.log.scoped(.@"problem-2");

pub fn main() !void {
    defer log.info("[Main] Exit", .{});
    log.info("[Main] Start", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const result = gpa.deinit();
        std.debug.assert(result == .ok);
    }

    const allocator = gpa.allocator();

    const host_address = try std.net.Address.parseIp(settings.default_address, settings.default_port);
    var server = try host_address.listen(.{});
    defer server.deinit();

    log.info("[Main] Server listening on '{}'", .{server.listen_address});

    var thread_pool: std.Thread.Pool = undefined;
    try thread_pool.init(.{
        .allocator = allocator,
        .n_jobs = settings.default_num_jobs,
    });
    defer thread_pool.deinit();

    const running = true;
    while (running) {
        log.debug("[Main] Waiting for connection...", .{});
        if (server.accept()) |new_connection| {
            errdefer new_connection.stream.close();
            try thread_pool.spawn(handle_connection, .{new_connection});
        } else |accept_error| {
            switch (accept_error) {
                error.WouldBlock => {},
                else => |err| {
                    log.err("[Main] Error accepting connection: {}", .{err});
                },
            }
        }
    }

    return;
}

fn handle_connection(connection: std.net.Server.Connection) void {
    defer connection.stream.close();
    defer log.debug("[{}] Connection closed", .{connection.address});

    log.debug("[{}] Connection accepted", .{connection.address});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const result = gpa.deinit();
        std.debug.assert(result == .ok);
    }

    const Record = struct {
        timestamp: i32,
        price: i32,

        fn compare_timestamp(_: void, lhs: i32, rhs: @This()) std.math.Order {
            return std.math.order(lhs, rhs.timestamp);
        }
    };
    var records = std.ArrayList(Record).init(gpa.allocator());
    defer records.deinit();

    const reader = connection.stream.reader();
    const writer = connection.stream.writer();
    while (true) {
        var message_buffer: [9]u8 = undefined;

        const num_bytes_read = reader.readAll(message_buffer[0..]) catch |err| {
            log.err("[{}] Failed to read message. Error = {}", .{ connection.address, err });
            return;
        };

        const message = message_buffer[0..num_bytes_read];
        const expected_message_length = 9;
        if (message.len != expected_message_length) {
            log.err("[{}] Invalid message length. Expected = {}, Actual = {}", .{ connection.address, expected_message_length, num_bytes_read });
            return;
        }

        const message_type: u8 = message_buffer[0];
        switch (message_type) {
            'I' => {
                const InsertMessage = packed struct {
                    message_type: u8,
                    timestamp: i32,
                    price: i32,
                };
                const instruction = bytes_to_value(InsertMessage, message[0..9], .big);

                const target_index = common.utility.lower_bound(Record, instruction.timestamp, records.items, {}, Record.compare_timestamp);
                if (target_index < records.items.len and records.items[target_index].timestamp == instruction.timestamp) {
                    // Value already exists, by protocol definition this is undefined behavior.
                    // We choose to overwrite the value
                    var record = records.items[target_index];
                    record.price = instruction.price;
                    records.items[target_index] = record;
                } else {
                    records.insert(target_index, Record{ .timestamp = instruction.timestamp, .price = instruction.price }) catch |err| {
                        log.err("[{}] Error recording price. Error = {}", .{ connection.address, err });
                        return;
                    };
                }

                log.debug("[{}] Inserted record. Timestamp = {}, Price = {}", .{ connection.address, instruction.timestamp, instruction.price });
            },
            'Q' => {
                const QueryMessage = packed struct {
                    message_type: u8,
                    min_timestamp: i32,
                    max_timestamp: i32,
                };
                const instruction = bytes_to_value(QueryMessage, message[0..9], .big);

                var sum: i128 = 0;
                var num_entries: usize = 0;

                if (instruction.min_timestamp <= instruction.max_timestamp) {
                    const lower_bound_index = common.utility.lower_bound(Record, instruction.min_timestamp, records.items, {}, Record.compare_timestamp);
                    const upper_bound_index = common.utility.upper_bound(Record, instruction.max_timestamp, records.items, {}, Record.compare_timestamp);
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

                log.debug("[{}] Price query. MinTimestamp = {}, MaxTimestamp = {}, Mean = {}", .{ connection.address, instruction.min_timestamp, instruction.max_timestamp, mean_price });
                writer.writeInt(i32, @intCast(mean_price), .big) catch |err| {
                    log.err("[{}] Failed to write query response. Error = {}", .{ connection.address, err });
                };
            },
            else => {
                log.err("[{}] Invalid message type. Type = {}", .{ connection.address, message_type });
                return;
            },
        }
    }
}

fn bytes_to_value(comptime T: type, bytes: []const u8, endian: std.builtin.Endian) T {
    var result = std.mem.bytesToValue(T, bytes);

    const native_endian = @import("builtin").target.cpu.arch.endian();
    if (native_endian != endian) {
        std.mem.byteSwapAllFields(T, &result);
    }

    return result;
}
