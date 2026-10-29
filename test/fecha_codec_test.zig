//! Las conversiones wire conservan representación, ownership y errores de memoria.
const std = @import("std");
const codec = @import("aida_rest").date_codec;
const allocator = std.testing.allocator;

test "Fecha codecs round trip bounds and preserve JSON field order" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for ([_][]const u8{ "0001-01-01", "1900-02-28", "2000-02-29", "2024-02-29", "2100-02-28", "9999-12-31" }) |iso| {
        const value = try codec.postgresToJson(arena.allocator(), iso);
        try std.testing.expectEqualStrings("año", value.object.keys()[0]);
        try std.testing.expectEqualStrings("mes", value.object.keys()[1]);
        try std.testing.expectEqualStrings("día", value.object.keys()[2]);
        try std.testing.expectEqualStrings(iso, try codec.jsonToPostgres(arena.allocator(), value));
        var buffer: [128]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        try std.json.Stringify.value(value, .{}, &writer);
        try std.testing.expectEqualStrings(iso, try codec.queryToPostgres(arena.allocator(), writer.buffered()));
        try std.testing.expectEqualStrings(iso, try codec.queryToPostgres(arena.allocator(), iso));
    }
}

test "Fecha query and stored codecs reject impossible or noncanonical ISO" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "2025-02-30", "1900-02-29", "2100-02-29",  "2024-04-31",           "0000-01-01", "10000-01-01",
        "2024-00-01", "2024-13-01", "2024-01-00",  "2024-01-32",           "+024-02-29", "2024-+2-29",
        "2024-02-+9", "2024-2-29",  "2024-02-29 ", "2024-02-29T00:00:00Z", "infinity",   "null",
    }) |iso| {
        try std.testing.expectError(error.InvalidValue, codec.queryToPostgres(arena.allocator(), iso));
        try std.testing.expectError(error.InvalidValue, codec.postgresToJson(arena.allocator(), iso));
    }
}

test "Fecha object codecs reject invalid calendar values and incompatible shapes" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "{\"año\":2025,\"mes\":2,\"día\":30}",
        "{\"año\":1900,\"mes\":2,\"día\":29}",
        "{\"año\":0,\"mes\":1,\"día\":1}",
        "{\"año\":10000,\"mes\":1,\"día\":1}",
        "{\"año\":2024,\"mes\":13,\"día\":1}",
        "{\"año\":2024,\"mes\":1,\"día\":0}",
        "{\"año\":2024,\"mes\":2}",
        "{\"año\":2024,\"mes\":2,\"día\":29,\"extra\":1}",
        "null",
        "[]",
        "\"2024-02-29\"",
    }) |body| {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidValue, codec.jsonToPostgres(arena.allocator(), parsed.value));
        try std.testing.expectError(error.InvalidValue, codec.queryToPostgres(arena.allocator(), body));
    }
}

test "Fecha codecs return data independent of their textual input" {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var source = "2024-02-29".*;
    const text = try codec.queryToPostgres(arena.allocator(), &source);
    const object = try codec.postgresToJson(arena.allocator(), &source);
    @memset(&source, 'x');
    try std.testing.expectEqualStrings("2024-02-29", text);
    try std.testing.expect(object.object.get("año").?.integer == 2024);
    try std.testing.expect(object.object.get("mes").?.integer == 2);
    try std.testing.expect(object.object.get("día").?.integer == 29);
}

fn queryWithAllocationFailures(backing: std.mem.Allocator, input: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    _ = try codec.queryToPostgres(arena.allocator(), input);
}

fn resultWithAllocationFailures(backing: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    _ = try codec.postgresToJson(arena.allocator(), "2024-02-29");
}

test "Fecha query codec propagates all allocation failures and cleans partial parsing" {
    try std.testing.checkAllAllocationFailures(allocator, queryWithAllocationFailures, .{"2024-02-29"});
    try std.testing.checkAllAllocationFailures(allocator, queryWithAllocationFailures, .{"{\"año\":2024,\"mes\":2,\"día\":29}"});
}

test "Fecha stored codec propagates all allocation failures and cleans partial objects" {
    try std.testing.checkAllAllocationFailures(allocator, resultWithAllocationFailures, .{});
}
