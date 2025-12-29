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
        .io = io,
    };

    const running: bool = true;
    log.debug("Waiting for connection...", .{});
    while (running) {
        const stream = try server.accept(io);
        try group.concurrent(io, accept, .{ &context, stream });
    }

    return;
}

const Context = struct {
    io: std.Io,
};

fn accept(context: *Context, stream: std.Io.net.Stream) void {
    const id = stream.socket.address;

    log.debug("[{f}] Connection accepted", .{id});
    defer log.debug("[{f}] Connection closed", .{id});

    const io = context.io;
    defer stream.close(io);

    var message_buffer: [1024 * 1024]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&message_buffer);

    var recv_buffer: [1024 * 1024]u8 = undefined;
    var send_buffer: [256]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buffer);
    var conn_writer = stream.writer(io, &send_buffer);

    while (true) {
        defer fba.reset();
        const request_allocator = fba.allocator();

        const message = conn_reader.interface.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => {
                log.err("[{f}] Error receiving message: {s}", .{ id, @errorName(conn_reader.err.?) });
                return;
            },
            error.StreamTooLong => {
                log.err("[{f}] Error receiving message: OOM", .{id});
                return;
            },
        } orelse break;
        if (message.len == 0)
            continue;

        var request_timer = std.time.Timer.start() catch @panic("Failed to start timer");
        defer log.debug("[{f}] request took {d}ms", .{ id, @divTrunc(request_timer.read(), std.time.ns_per_ms) });

        log.debug("[{f}] request = '{s}'", .{ id, message });

        const request = std.json.parseFromSliceLeaky(Request, request_allocator, message, .{
            .duplicate_field_behavior = .@"error",
            .ignore_unknown_fields = true,
            .max_value_len = 1000,
        }) catch |parse_error| {
            log.debug("[{f}] Malformed request. Error = {s}", .{ id, @errorName(parse_error) });
            conn_writer.interface.writeAll("{\"error\":\"Malformed request.\"}\n") catch return;
            conn_writer.interface.flush() catch return;
            return;
        };

        if (std.mem.eql(u8, request.method, "isPrime")) {
            var response = Response{
                .method = "isPrime",
                .prime = false,
            };

            switch (request.number) {
                .integer => |int| {
                    response.prime = is_prime(i64, int);
                },
                .float => {},
                .number_string => {
                    if (std.json.parseFromValueLeaky(i256, request_allocator, request.number, .{})) |big_int| {
                        response.prime = is_prime(i256, big_int);
                    } else |err| {
                        log.debug("[{f}] number '{}' was a number string that we couldn't parse. Error = {s}", .{ id, request.number, @errorName(err) });
                        conn_writer.interface.writeAll("{\"error\":\"'number' value was not a number.\"}\n") catch return;
                        conn_writer.interface.flush() catch return;
                        return;
                    }
                },
                else => {
                    log.debug("[{f}] number '{}' was not an accepted type", .{ id, request.number });
                    conn_writer.interface.writeAll("{\"error\":\"'number' value was not a number.\"}\n") catch return;
                    conn_writer.interface.flush() catch return;
                    return;
                },
            }

            var conn_json_writer: std.json.Stringify = .{
                .writer = &conn_writer.interface,
                .options = .{
                    .whitespace = .minified,
                },
            };
            conn_json_writer.write(response) catch |err| {
                log.err("[{f}] Failed to write json response. Error = {}", .{ id, err });
                return;
            };
            conn_writer.interface.writeByte('\n') catch |err| {
                log.err("[{f}] Failed to write response terminator. Error = {}", .{ id, err });
                return;
            };
            conn_writer.interface.flush() catch {
                log.err("[{f}] Failed to flush response stream. Error = {?}", .{ id, conn_writer.err });
                return;
            };

            log.debug("[{f}] response = '{}'", .{ id, response.prime });
        } else {
            log.debug("[{f}] Invalid request method '{s}'", .{ id, request.method });
            conn_writer.interface.writeAll("{\"error\":\"Unrecognized method.\"}\n") catch return;
            conn_writer.interface.flush() catch return;
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

fn is_prime(comptime RawT: type, raw_value: RawT) bool {
    if (raw_value <= 1) return false;
    const T = @Int(.unsigned, @typeInfo(RawT).int.bits);
    const value = @as(T, @intCast(raw_value));
    if (value == 2) return true;
    if (value % 2 == 0) return false;

    const limit = std.math.sqrt(value);
    var i: T = 3;
    while (i < limit) {
        defer i += 2;
        if (value % i == 0) {
            return false;
        }
    }
    return true;
}

const std = @import("std");
pub const std_options: std.Options = .{
    .log_level = .debug,
};
const common = @import("common");
const config = common.config;
const log = std.log.scoped(.@"problem-1");

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
