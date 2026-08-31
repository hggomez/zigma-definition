//! Small sequential HTTP/1.1 adapter for `zigma_rest` using Zig's standard
//! library networking. One TCP connection serves one request and is closed.

const std = @import("std");
const rest = @import("zigma_rest");

pub const Config = struct {
    address: []const u8 = "127.0.0.1",
    port: u16 = 8080,
    max_header_bytes: usize = 16 * 1024,
    max_body_bytes: usize = 1024 * 1024,
    /// Primarily useful for deterministic embedding and tests. `null` serves
    /// until the process is stopped.
    max_requests: ?usize = null,
};

fn methodFromStd(method: std.http.Method) rest.Method {
    return switch (method) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .DELETE => .DELETE,
        else => .other,
    };
}

fn send(
    request: *std.http.Server.Request,
    status: u16,
    body: []const u8,
) !void {
    try request.respond(body, .{
        .status = @fromBackingInt(@intCast(status)),
        .keep_alive = false,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
}

pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    api: anytype,
    repository: anytype,
    config: Config,
) !void {
    const address = try std.Io.net.IpAddress.parse(config.address, config.port);
    var listener = try address.listen(io, .{ .reuse_address = true });
    defer listener.deinit(io);

    var served: usize = 0;
    while (config.max_requests == null or served < config.max_requests.?) {
        const stream = try listener.accept(io);
        defer stream.close(io);

        var request_arena = std.heap.ArenaAllocator.init(allocator);
        defer request_arena.deinit();
        const request_allocator = request_arena.allocator();
        const input_buffer = try request_allocator.alloc(u8, config.max_header_bytes);
        const output_buffer = try request_allocator.alloc(u8, 16 * 1024);
        var stream_reader = stream.reader(io, input_buffer);
        var stream_writer = stream.writer(io, output_buffer);
        var server = std.http.Server.init(&stream_reader.interface, &stream_writer.interface);
        var request = server.receiveHead() catch {
            served += 1;
            continue;
        };

        const method = methodFromStd(request.head.method);
        const target = try request_allocator.dupe(u8, request.head.target);
        const content_type = if (request.head.content_type) |value|
            try request_allocator.dupe(u8, value)
        else
            null;

        if (request.head.content_length) |length| {
            if (length > config.max_body_bytes) {
                try send(
                    &request,
                    413,
                    "{\"error\":{\"code\":\"body_too_large\",\"message\":\"Request body exceeds the configured limit\"}}",
                );
                served += 1;
                continue;
            }
        }

        var body_buffer: [8192]u8 = undefined;
        const body_reader = request.readerExpectContinue(&body_buffer) catch {
            served += 1;
            continue;
        };
        const body = body_reader.allocRemaining(
            request_allocator,
            .limited(config.max_body_bytes),
        ) catch |err| switch (err) {
            error.StreamTooLong => {
                try send(
                    &request,
                    413,
                    "{\"error\":{\"code\":\"body_too_large\",\"message\":\"Request body exceeds the configured limit\"}}",
                );
                served += 1;
                continue;
            },
            else => return err,
        };

        const response = api.handle(request_allocator, repository, .{
            .method = method,
            .target = target,
            .content_type = content_type,
            .body = body,
        }) catch {
            try send(
                &request,
                500,
                "{\"error\":{\"code\":\"internal_error\",\"message\":\"Internal server error\"}}",
            );
            served += 1;
            continue;
        };
        try send(&request, response.status, response.body);
        served += 1;
    }
}
