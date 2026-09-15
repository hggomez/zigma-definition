//! In-memory HTTP backend that speaks the same `/api/<entity>` contract as `zigma_rest`.
//! Injected `system`: `type_defs`, `entity_defs`, optional `seeds`.
//! Injected `app_rest`: `Api` (generated REST controller for that system).
//! CORS is enabled so the WASM page on another origin can call this server.

const std = @import("std");
const zigma = @import("zigma");
const rest = @import("zigma_rest");
const system = @import("system");
const app_rest = @import("app_rest");
const MemoryRepository = @import("memory_repository").MemoryRepository;

const port: u16 = 8080;
const Model = zigma.System(system.type_defs, system.entity_defs);
const Repo = MemoryRepository(Model);
const entity_names = @typeInfo(@TypeOf(Model.info)).@"struct".field_names;

const cors_origin = std.http.Header{
    .name = "Access-Control-Allow-Origin",
    .value = "*",
};
const cors_methods = std.http.Header{
    .name = "Access-Control-Allow-Methods",
    .value = "GET, POST, PUT, DELETE, OPTIONS",
};
const cors_headers = std.http.Header{
    .name = "Access-Control-Allow-Headers",
    .value = "Content-Type",
};
const json_content_type = std.http.Header{
    .name = "Content-Type",
    .value = "application/json",
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var repository = try Repo.init(gpa);
    defer repository.deinit();
    try seed(gpa, &repository);

    var api = app_rest.Api.init(.{});

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", port);
    var tcp_server = try address.listen(io, .{ .reuse_address = true });
    defer tcp_server.deinit(io);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    try stdout.print("backend running on port {d}...\n", .{port});
    try stdout.flush();

    while (true) {
        const stream = try tcp_server.accept(io);
        handleConnection(gpa, io, stdout, stream, &api, &repository) catch |err| {
            stdout.print("error: {t}\n", .{err}) catch {};
            stdout.flush() catch {};
        };
        stream.close(io);
    }
}

fn handleConnection(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    stream: std.Io.net.Stream,
    api: *app_rest.Api,
    repository: *Repo,
) !void {
    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [4096]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server = std.http.Server.init(&connection_reader.interface, &connection_writer.interface);

    var request = try server.receiveHead();

    if (request.head.method == .OPTIONS) {
        try request.respond("", .{
            .status = .no_content,
            .keep_alive = false,
            .extra_headers = &.{ cors_origin, cors_methods, cors_headers },
        });
        return;
    }

    var request_arena = std.heap.ArenaAllocator.init(gpa);
    defer request_arena.deinit();
    const request_allocator = request_arena.allocator();

    const target = try request_allocator.dupe(u8, request.head.target);
    const content_type = if (request.head.content_type) |value|
        try request_allocator.dupe(u8, value)
    else
        null;

    const method: rest.Method = switch (request.head.method) {
        .GET => .GET,
        .POST => .POST,
        .PUT => .PUT,
        .DELETE => .DELETE,
        else => .other,
    };

    var body: []const u8 = "";
    if (method == .POST or method == .PUT or method == .DELETE) {
        var body_buffer: [8192]u8 = undefined;
        const body_reader = try requestReader(&request, &body_buffer);
        body = try body_reader.allocRemaining(request_allocator, .limited(1024 * 1024));
    }

    try stdout.print("{t} {s}\n", .{ request.head.method, target });
    if (body.len != 0) try stdout.print("{s}\n", .{body});
    try stdout.flush();

    const response = api.handle(request_allocator, repository, .{
        .method = method,
        .target = target,
        .content_type = content_type,
        .body = body,
    }) catch rest.Response{
        .status = 500,
        .body = "{\"error\":{\"code\":\"internal_error\",\"message\":\"Internal server error\"}}",
    };

    try request.respond(response.body, .{
        .status = @fromBackingInt(@intCast(response.status)),
        .keep_alive = false,
        .extra_headers = &.{ json_content_type, cors_origin },
    });
}

fn requestReader(request: *std.http.Server.Request, buffer: []u8) std.http.Server.Request.ExpectContinueError!*std.Io.Reader {
    const transfer_encoding = request.head.transfer_encoding;
    const content_length = request.head.content_length;
    const advertised = content_length != null or transfer_encoding == .chunked;
    if (advertised) {
        const flush = request.head.expect != null;
        try request.writeExpectContinue();
        if (flush) try request.server.out.flush();
        return request.server.reader.bodyReader(buffer, transfer_encoding, content_length);
    }
    return request.readerExpectContinue(buffer);
}

fn seed(gpa: std.mem.Allocator, repository: *Repo) !void {
    if (!@hasDecl(system, "seeds")) return;
    inline for (entity_names) |entity_name| {
        if (!@hasField(@TypeOf(system.seeds), entity_name)) continue;
        const entity = @field(Model.info, entity_name);
        for (@field(system.seeds, entity_name)) |row| {
            var values_buf: [64]rest.FieldValue = undefined;
            const values = try rowToFieldValues(gpa, entity, row, &values_buf);
            defer freeFieldValues(gpa, values);
            var result = try repository.insert(gpa, entity_name, values);
            result.deinit();
        }
    }
}

fn rowToFieldValues(
    allocator: std.mem.Allocator,
    comptime entity: anytype,
    row: anytype,
    buf: []rest.FieldValue,
) ![]rest.FieldValue {
    const field_names = @typeInfo(@TypeOf(entity.fields)).@"struct".field_names;
    if (field_names.len > buf.len) return error.OutOfMemory;
    inline for (field_names, 0..) |field_name, i| {
        buf[i] = .{
            .name = field_name,
            .value = try zigValueToText(allocator, @field(row, field_name)),
        };
    }
    return buf[0..field_names.len];
}

fn freeFieldValues(allocator: std.mem.Allocator, values: []rest.FieldValue) void {
    for (values) |value| if (value.value) |bytes| allocator.free(bytes);
}

fn zigValueToText(allocator: std.mem.Allocator, value: anytype) !?[]u8 {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => {
            if (value) |inner| return zigValueToText(allocator, inner);
            return null;
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return try allocator.dupe(u8, value);
            @compileError("unsupported seed field type " ++ @typeName(T));
        },
        .int => return try std.fmt.allocPrint(allocator, "{d}", .{value}),
        .bool => return try allocator.dupe(u8, if (value) "true" else "false"),
        .@"struct" => {
            if (@hasField(T, "año") and @hasField(T, "mes") and @hasField(T, "día")) {
                return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{
                    value.@"año",
                    value.mes,
                    value.@"día",
                });
            }
            @compileError("unsupported seed struct " ++ @typeName(T));
        },
        else => @compileError("unsupported seed field type " ++ @typeName(T)),
    }
}
