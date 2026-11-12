//! El cliente envía UTC canónico; PostgreSQL puede devolver otro huso horario.
const std = @import("std");
const rest = @import("zigma_rest");
const instant = @import("instant");

fn fromQuery(allocator: std.mem.Allocator, value: []const u8) rest.CodecError![]const u8 {
    _ = try instant.parseCanonical(value);
    return allocator.dupe(u8, value);
}

fn fromJson(allocator: std.mem.Allocator, value: std.json.Value) rest.CodecError![]const u8 {
    if (value != .string) return error.InvalidValue;
    return fromQuery(allocator, value.string);
}

fn toJson(allocator: std.mem.Allocator, value: []const u8) rest.CodecError!std.json.Value {
    const parsed = try instant.parsePostgres(value);
    return .{ .string = try parsed.format(allocator) };
}

pub const codec = rest.Codec{
    .queryToPostgres = fromQuery,
    .jsonToPostgres = fromJson,
    .postgresToJson = toJson,
};
