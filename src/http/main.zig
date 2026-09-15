//! Generic HTTP backend: in-memory lists per entity of the injected `system`.
//! `system` must export `type_defs` and `entity_defs`. Optional `seeds` is a
//! struct of row arrays keyed by entity name.

const std = @import("std");
const zigma = @import("zigma");
const system = @import("system");
const zigma_json = @import("zigma_json");

const port: u16 = 8080;
const entity_names = @typeInfo(@TypeOf(system.entity_defs)).@"struct".field_names;
const entity_count = entity_names.len;

const cors_origin = std.http.Header{
    .name = "Access-Control-Allow-Origin",
    .value = "*",
};

const cors_methods = std.http.Header{
    .name = "Access-Control-Allow-Methods",
    .value = "POST, PUT, DELETE, GET, OPTIONS",
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

    var lists: [entity_count]std.ArrayList([]const u8) = undefined;
    for (&lists) |*list| list.* = .empty;
    defer {
        for (&lists) |*list| {
            for (list.items) |item| gpa.free(item);
            list.deinit(gpa);
        }
    }
    try seed(gpa, &lists);

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
        handleConnection(gpa, io, stdout, stream, &lists) catch |err| {
            stdout.print("error: {t}\n", .{err}) catch {};
            stdout.flush() catch {};
        };
        stream.close(io);
    }
}

fn seed(gpa: std.mem.Allocator, lists: *[entity_count]std.ArrayList([]const u8)) !void {
    if (!@hasDecl(system, "seeds")) return;
    inline for (entity_names, 0..) |name, i| {
        if (@hasField(@TypeOf(system.seeds), name)) {
            for (@field(system.seeds, name)) |row| {
                try appendJson(gpa, &lists[i], row);
            }
        }
    }
}

fn appendJson(gpa: std.mem.Allocator, list: *std.ArrayList([]const u8), row: anytype) !void {
    var buf: [8192]u8 = undefined;
    const json = try zigma_json.stringifyRecord(row, &buf);
    try list.append(gpa, try gpa.dupe(u8, json));
}

fn handleConnection(
    gpa: std.mem.Allocator,
    io: std.Io,
    stdout: *std.Io.Writer,
    stream: std.Io.net.Stream,
    lists: *[entity_count]std.ArrayList([]const u8),
) !void {
    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [4096]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        try handleRequest(gpa, stdout, &request, lists);
    }
}

fn handleRequest(
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    request: *std.http.Server.Request,
    lists: *[entity_count]std.ArrayList([]const u8),
) !void {
    switch (request.head.method) {
        .OPTIONS => try request.respond("", .{
            .extra_headers = &.{ cors_origin, cors_methods, cors_headers },
        }),
        .GET => try handleGet(gpa, stdout, request, lists),
        .POST => try handleWrite(gpa, stdout, request, lists, .post),
        .PUT => try handleWrite(gpa, stdout, request, lists, .put),
        .DELETE => try handleWrite(gpa, stdout, request, lists, .delete),
        else => {
            try stdout.print("{t}\n", .{request.head.method});
            try stdout.print("error: not implemented\n", .{});
            try reply(stdout, request, .not_implemented, "Not Implemented", &.{cors_origin});
        },
    }
}

fn splitTarget(target: []const u8) struct { path: []const u8, query: []const u8 } {
    const q = std.mem.indexOfScalar(u8, target, '?') orelse
        return .{ .path = target, .query = "" };
    return .{ .path = target[0..q], .query = target[q + 1 ..] };
}

fn entityNameOf(path: []const u8) ?[]const u8 {
    if (path.len < 2 or path[0] != '/') return null;
    const rest = path[1..];
    if (rest.len == 0 or std.mem.indexOfScalar(u8, rest, '/') != null) return null;
    return rest;
}

const QueryPair = struct {
    name_buf: []u8,
    value_buf: []u8,
    name: []const u8,
    value: []const u8,
};

fn decodeComponent(gpa: std.mem.Allocator, encoded: []const u8) !QueryPair {
    const name_src, const value_src = blk: {
        if (std.mem.indexOfScalar(u8, encoded, '=')) |eq| {
            break :blk .{ encoded[0..eq], encoded[eq + 1 ..] };
        }
        break :blk .{ encoded, "" };
    };
    const name_buf = try gpa.dupe(u8, name_src);
    errdefer gpa.free(name_buf);
    for (name_buf) |*c| {
        if (c.* == '+') c.* = ' ';
    }
    const value_buf = try gpa.dupe(u8, value_src);
    errdefer gpa.free(value_buf);
    for (value_buf) |*c| {
        if (c.* == '+') c.* = ' ';
    }
    return .{
        .name_buf = name_buf,
        .value_buf = value_buf,
        .name = std.Uri.percentDecodeInPlace(name_buf),
        .value = std.Uri.percentDecodeInPlace(value_buf),
    };
}

fn parseQuery(gpa: std.mem.Allocator, query: []const u8) ![]QueryPair {
    var list: std.ArrayList(QueryPair) = .empty;
    errdefer {
        for (list.items) |pair| {
            gpa.free(pair.name_buf);
            gpa.free(pair.value_buf);
        }
        list.deinit(gpa);
    }
    if (query.len == 0) return list.toOwnedSlice(gpa);
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |raw| {
        if (raw.len == 0) continue;
        try list.append(gpa, try decodeComponent(gpa, raw));
    }
    return list.toOwnedSlice(gpa);
}

fn freeQuery(gpa: std.mem.Allocator, pairs: []QueryPair) void {
    for (pairs) |pair| {
        gpa.free(pair.name_buf);
        gpa.free(pair.value_buf);
    }
    gpa.free(pairs);
}

const PkQueryError = error{ MissingPk, ExtraQuery, DuplicatePk, InvalidPk };

fn parseQueryValue(comptime T: type, raw: []const u8) PkQueryError!T {
    return zigma_json.parseFieldValue(T, raw) catch error.InvalidPk;
}

fn pkFromQuery(comptime entity: anytype, pairs: []const QueryPair) PkQueryError!zigma.RecordInstanceType(system.type_defs, zigma.extractPk(entity)) {
    const Pk = zigma.RecordInstanceType(system.type_defs, zigma.extractPk(entity));
    var pk: Pk = undefined;
    var seen: [entity.pk.len]bool = @splat(false);
    for (pairs) |pair| {
        var found = false;
        inline for (entity.pk, 0..) |name, i| {
            if (std.mem.eql(u8, pair.name, name)) {
                if (seen[i]) return error.DuplicatePk;
                seen[i] = true;
                found = true;
                @field(pk, name) = try parseQueryValue(@TypeOf(@field(pk, name)), pair.value);
            }
        }
        if (!found) return error.ExtraQuery;
    }
    for (seen) |s| {
        if (!s) return error.MissingPk;
    }
    return pk;
}

fn pkQueryMessage(err: PkQueryError) []const u8 {
    return switch (err) {
        error.MissingPk => "pk required",
        error.ExtraQuery => "extra query",
        error.DuplicatePk => "duplicate pk",
        error.InvalidPk => "invalid pk",
    };
}

fn listFor(lists: *[entity_count]std.ArrayList([]const u8), name: []const u8) ?*std.ArrayList([]const u8) {
    inline for (entity_names, 0..) |n, i| {
        if (std.mem.eql(u8, name, n)) return &lists[i];
    }
    return null;
}

fn joinJsonArray(items: []const []const u8, buf: []u8) error{NoSpaceLeft}![]const u8 {
    var pos: usize = 0;
    if (pos >= buf.len) return error.NoSpaceLeft;
    buf[pos] = '[';
    pos += 1;
    for (items, 0..) |item, i| {
        if (i != 0) {
            if (pos >= buf.len) return error.NoSpaceLeft;
            buf[pos] = ',';
            pos += 1;
        }
        if (pos + item.len > buf.len) return error.NoSpaceLeft;
        @memcpy(buf[pos..][0..item.len], item);
        pos += item.len;
    }
    if (pos >= buf.len) return error.NoSpaceLeft;
    buf[pos] = ']';
    pos += 1;
    return buf[0..pos];
}

fn printRequest(gpa: std.mem.Allocator, stdout: *std.Io.Writer, method: []const u8, target: []const u8, body: []const u8) !void {
    try stdout.print("{s} {s}\n", .{ method, target });
    if (body.len == 0) {
        try stdout.flush();
        return;
    }
    if (std.json.parseFromSlice(std.json.Value, gpa, body, .{})) |parsed| {
        defer parsed.deinit();
        try stdout.print("{f}\n", .{std.json.fmt(parsed.value, .{ .whitespace = .indent_2 })});
    } else |_| {
        try stdout.print("{s}\n", .{body});
    }
    try stdout.flush();
}

fn printErr(stdout: *std.Io.Writer, msg: []const u8) !void {
    try stdout.print("error: {s}\n", .{msg});
    try stdout.flush();
}

fn reply(
    stdout: *std.Io.Writer,
    request: *std.http.Server.Request,
    status: std.http.Status,
    body: []const u8,
    extra_headers: []const std.http.Header,
) !void {
    try stdout.print("{d} {s}\n", .{ @intFromEnum(status), body });
    try stdout.flush();
    try request.respond(body, .{
        .status = status,
        .extra_headers = extra_headers,
    });
}

fn handleGet(
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    request: *std.http.Server.Request,
    lists: *[entity_count]std.ArrayList([]const u8),
) !void {
    try printRequest(gpa, stdout, "GET", request.head.target, "");

    const parts = splitTarget(request.head.target);
    if (parts.query.len != 0) {
        try printErr(stdout, "unexpected query");
        try reply(stdout, request, .bad_request, "{\"status\":\"invalid\"}", &.{ json_content_type, cors_origin });
        return;
    }
    const name = entityNameOf(parts.path) orelse {
        try printErr(stdout, "not found");
        try reply(stdout, request, .not_found, "Not Found", &.{cors_origin});
        return;
    };
    const list = listFor(lists, name) orelse {
        try printErr(stdout, "not found");
        try reply(stdout, request, .not_found, "Not Found", &.{cors_origin});
        return;
    };

    var json_buf: [65536]u8 = undefined;
    const json = try joinJsonArray(list.items, &json_buf);
    try reply(stdout, request, .ok, json, &.{ json_content_type, cors_origin });
}

fn valuesEqual(a: anytype, b: @TypeOf(a)) bool {
    switch (@typeInfo(@TypeOf(a))) {
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return std.mem.eql(u8, a, b);
        },
        .int, .bool => return a == b,
        .@"struct" => {
            inline for (@typeInfo(@TypeOf(a)).@"struct".field_names) |name| {
                if (!valuesEqual(@field(a, name), @field(b, name))) return false;
            }
            return true;
        },
        else => {},
    }
    return false;
}

fn pkEqual(comptime entity: anytype, a: anytype, b: anytype) bool {
    inline for (entity.pk) |name| {
        if (!valuesEqual(@field(a, name), @field(b, name))) return false;
    }
    return true;
}

fn replaceByPk(
    gpa: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    comptime entity: anytype,
    url_pk: anytype,
    new_row: anytype,
) !bool {
    const Row = @TypeOf(new_row);
    var buf: [8192]u8 = undefined;
    const json = try zigma_json.stringifyRecord(new_row, &buf);
    for (list.items, 0..) |old_json, i| {
        const parsed = std.json.parseFromSlice(Row, gpa, old_json, .{}) catch continue;
        defer parsed.deinit();
        if (pkEqual(entity, parsed.value, url_pk)) {
            gpa.free(old_json);
            list.items[i] = try gpa.dupe(u8, json);
            return true;
        }
    }
    return false;
}

fn removeByPk(
    gpa: std.mem.Allocator,
    list: *std.ArrayList([]const u8),
    comptime entity: anytype,
    url_pk: anytype,
) bool {
    const Row = zigma.RecordInstanceType(system.type_defs, entity.fields);
    for (list.items, 0..) |old_json, i| {
        const parsed = std.json.parseFromSlice(Row, gpa, old_json, .{}) catch continue;
        defer parsed.deinit();
        if (pkEqual(entity, parsed.value, url_pk)) {
            gpa.free(old_json);
            _ = list.orderedRemove(i);
            return true;
        }
    }
    return false;
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

fn handleWrite(
    gpa: std.mem.Allocator,
    stdout: *std.Io.Writer,
    request: *std.http.Server.Request,
    lists: *[entity_count]std.ArrayList([]const u8),
    kind: enum { post, put, delete },
) !void {
    var path_buf: [1024]u8 = undefined;
    if (request.head.target.len > path_buf.len) return error.TargetTooLong;
    const path = path_buf[0..request.head.target.len];
    @memcpy(path, request.head.target);

    const label = switch (kind) {
        .post => "POST",
        .put => "PUT",
        .delete => "DELETE",
    };

    var body_buf: [4096]u8 = undefined;
    const body_reader = try requestReader(request, &body_buf);
    const body = try body_reader.allocRemaining(gpa, .unlimited);
    defer gpa.free(body);

    try printRequest(gpa, stdout, label, path, if (kind == .delete) "" else body);

    const parts = splitTarget(path);
    const name = entityNameOf(parts.path) orelse {
        try printErr(stdout, "not found");
        try reply(stdout, request, .not_found, "Not Found", &.{cors_origin});
        return;
    };

    if (kind == .post and parts.query.len != 0) {
        try printErr(stdout, "unexpected query");
        try reply(stdout, request, .bad_request, "{\"status\":\"invalid\"}", &.{ json_content_type, cors_origin });
        return;
    }

    var matched = false;
    @setEvalBranchQuota(10000);
    inline for (entity_names, 0..) |n, i| {
        if (std.mem.eql(u8, name, n)) {
            matched = true;
            const entity = @field(system.entity_defs, n);
            if (kind == .post) {
                const Row = zigma.RecordInstanceType(system.type_defs, entity.fields);
                const parsed = std.json.parseFromSlice(Row, gpa, body, .{}) catch {
                    try printErr(stdout, "invalid json");
                    try reply(stdout, request, .bad_request, "{\"status\":\"invalid\"}", &.{ json_content_type, cors_origin });
                    return;
                };
                defer parsed.deinit();
                try appendJson(gpa, &lists[i], parsed.value);
            } else {
                const pairs = try parseQuery(gpa, parts.query);
                defer freeQuery(gpa, pairs);
                const url_pk = pkFromQuery(entity, pairs) catch |err| {
                    try printErr(stdout, pkQueryMessage(err));
                    try reply(stdout, request, .bad_request, "{\"status\":\"invalid\"}", &.{ json_content_type, cors_origin });
                    return;
                };
                if (kind == .put) {
                    const Row = zigma.RecordInstanceType(system.type_defs, entity.fields);
                    const parsed = std.json.parseFromSlice(Row, gpa, body, .{}) catch {
                        try printErr(stdout, "invalid json");
                        try reply(stdout, request, .bad_request, "{\"status\":\"invalid\"}", &.{ json_content_type, cors_origin });
                        return;
                    };
                    defer parsed.deinit();
                    if (!pkEqual(entity, parsed.value, url_pk)) {
                        try printErr(stdout, "pk mismatch");
                        try reply(stdout, request, .bad_request, "{\"status\":\"invalid\"}", &.{ json_content_type, cors_origin });
                        return;
                    }
                    const replaced = try replaceByPk(gpa, &lists[i], entity, url_pk, parsed.value);
                    if (!replaced) {
                        try printErr(stdout, "not found");
                        try reply(stdout, request, .not_found, "{\"status\":\"not found\"}", &.{ json_content_type, cors_origin });
                        return;
                    }
                } else {
                    if (!removeByPk(gpa, &lists[i], entity, url_pk)) {
                        try printErr(stdout, "not found");
                        try reply(stdout, request, .not_found, "{\"status\":\"not found\"}", &.{ json_content_type, cors_origin });
                        return;
                    }
                }
            }
        }
    }
    if (!matched) {
        try printErr(stdout, "not found");
        try reply(stdout, request, .not_found, "Not Found", &.{cors_origin});
        return;
    }

    try reply(stdout, request, .ok, "{\"status\": \"received\"}", &.{ json_content_type, cors_origin });
}
