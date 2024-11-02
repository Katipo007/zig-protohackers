const std = @import("std");
const common = @import("common");
const settings = common.settings;
const log = std.log.scoped(.@"problem-1");

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

    var memory_buffer: [settings.default_memory_per_worker]u8 = undefined;
    var buffered_allocator = std.heap.FixedBufferAllocator.init(memory_buffer[0..]);

    const max_message_size = 1024 * 40;
    var read_buffer: [max_message_size]u8 = undefined;

    var message_arena = std.heap.ArenaAllocator.init(buffered_allocator.allocator());
    defer message_arena.deinit();
    const message_allocator = message_arena.allocator();

    const reader = connection.stream.reader();
    const writer = connection.stream.writer();
    while (true) {
        defer _ = message_arena.reset(.retain_capacity);

        const maybe_message = reader.readUntilDelimiterOrEof(read_buffer[0..], '\n') catch |err| {
            log.err("[{}] Failed to read message. Error = {}", .{ connection.address, err });
            return;
        };
        if (maybe_message == null) {
            break;
        }

        const message = maybe_message.?;
        if (message.len == 0) {
            break;
        }

        //log.debug("Read message of '{}' bytes from '{}': {s}", .{ message.len, connection.address, message[0..@min(message.len, 60)] });

        const request = std.json.parseFromSliceLeaky(Request, message_allocator, message, .{
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = true,
            .max_value_len = 1000,
        }) catch |parse_error| {
            log.debug("[{}] Malformed request. Error = {}", .{ connection.address, parse_error });
            return;
        };

        if (std.mem.eql(u8, request.method, "isPrime")) {
            var response = Response{
                .method = "isPrime",
                .prime = false,
            };

            const start_time = std.time.nanoTimestamp();

            switch (request.number) {
                .integer => |int| {
                    response.prime = is_prime(i64, int);
                },
                .float => {},
                .number_string => {
                    if (std.json.parseFromValueLeaky(i256, message_allocator, request.number, .{})) |big_int| {
                        response.prime = is_prime(i256, big_int);
                    } else |err| {
                        log.err("[{}] number '{}' was a number string that we couldn't parse. Error = {}", .{ connection.address, request.number, err });
                        return;
                    }
                },
                else => {
                    log.err("[{}] number '{}' was not an accepted type", .{ connection.address, request.number });
                    return;
                },
            }

            const end_time = std.time.nanoTimestamp();

            log.debug("[{}] request = '{}', response = '{}' in {}ms", .{ connection.address, request.number, response.prime, @divTrunc(end_time - start_time, std.time.ns_per_ms) });
            std.json.stringify(response, .{}, writer) catch |err| {
                log.err("[{}] Failed to write json response. Error = {}", .{ connection.address, err });
                return;
            };
            _ = writer.write("\n") catch |err| {
                log.err("[{}] Failed to write response terminator. Error = {}", .{ connection.address, err });
                return;
            };
        } else {
            log.debug("[{}] Invalid request method '{s}'", .{ connection.address, request.method });
            return;
        }
    }
}
const Request = struct {
    method: []const u8,
    number: std.json.Value,
};

const Response = struct {
    method: []const u8,
    prime: bool,
};

fn is_prime(comptime T: type, value: T) bool {
    if (value < 2) {
        return false;
    }

    var i: T = 2;
    while (i < value) {
        if (@mod(value, i) == 0) {
            return false;
        }

        i += 1;
    }

    return true;
}
comptime {
    std.debug.assert(is_prime(i64, 2));
    std.debug.assert(!is_prime(i64, 4));
    std.debug.assert(is_prime(i64, 5));
    std.debug.assert(!is_prime(i64, 6));
    std.debug.assert(is_prime(i64, 7));
    std.debug.assert(is_prime(i64, 13));
    std.debug.assert(!is_prime(i64, 7256222));
    //@setEvalBranchQuota(10000000);
    //std.debug.assert(is_prime(i64, 24938377));
}
