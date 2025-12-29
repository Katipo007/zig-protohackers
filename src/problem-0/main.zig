pub fn main() !void {
    defer log.info("Exit", .{});
    log.info("Start", .{});

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

    log.info("Server listening on {f}", .{host_address});

    var group: std.Io.Group = .init;
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
}

const Context = struct {
    io: std.Io,
};

fn accept(context: *Context, stream: std.Io.net.Stream) void {
    const port = stream.socket.address.getPort();
    log.debug("Connection accepted on port {d}", .{port});
    defer log.info("Finished connection for port {d}", .{port});
    errdefer |err| log.err("Encountered error while handling client on port {d}. Error = {s}", .{ port, @errorName(err) });

    const io = context.io;
    defer stream.close(io);

    var recv_buffer: [1024]u8 = undefined;
    var send_buffer: [1024]u8 = undefined;
    var conn_reader = stream.reader(io, &recv_buffer);
    var conn_writer = stream.writer(io, &send_buffer);

    var total_num_bytes: usize = 0;
    while (true) {
        total_num_bytes += conn_reader.interface.streamRemaining(&conn_writer.interface) catch return;
        conn_writer.interface.flush() catch return;
        break;
    }

    log.info("Relayed a total of {d} bytes back to the client on port {d}", .{ total_num_bytes, port });
}

const std = @import("std");
const common = @import("common");
const config = common.config;
const log = std.log.scoped(.@"problem-0");
