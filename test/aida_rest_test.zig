const std = @import("std");
const aida_rest = @import("aida_rest");

test "AIDA fecha codec accepts real ISO dates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "2024-02-29",
        try aida_rest.date_codec.queryToPostgres(arena.allocator(), "2024-02-29"),
    );
    try std.testing.expectError(
        error.InvalidValue,
        aida_rest.date_codec.queryToPostgres(arena.allocator(), "2025-02-29"),
    );
    try std.testing.expectError(
        error.InvalidValue,
        aida_rest.date_codec.jsonToPostgres(arena.allocator(), .{ .string = "31/08/2026" }),
    );
}

test "AIDA email deliberately aliases the text codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "not-validated-yet",
        try aida_rest.codecs.email.queryToPostgres(arena.allocator(), "not-validated-yet"),
    );
}
