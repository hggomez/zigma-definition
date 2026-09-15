const std = @import("std");
const aida_rest = @import("aida_rest");
const rest = @import("zigma_rest");

test "AIDA fecha wire maps domain objects to ISO storage without calendar checks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings(
        "2024-02-29",
        try aida_rest.date_codec.queryToPostgres(arena.allocator(), "2024-02-29"),
    );
    // Not a real civil date: encoding only, no calendar validation in the wire codec.
    try std.testing.expectEqualStrings(
        "2025-02-30",
        try aida_rest.date_codec.queryToPostgres(arena.allocator(), "2025-02-30"),
    );

    const object_json = "{\"año\":2024,\"mes\":2,\"día\":29}";
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), object_json, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "2024-02-29",
        try aida_rest.date_codec.jsonToPostgres(arena.allocator(), parsed.value),
    );
    try std.testing.expectError(
        error.InvalidValue,
        aida_rest.date_codec.jsonToPostgres(arena.allocator(), .{ .string = "2024-02-29" }),
    );

    const json = try aida_rest.date_codec.postgresToJson(arena.allocator(), "2024-03-15");
    try std.testing.expect(json == .object);
    try std.testing.expect(json.object.get("año").?.integer == 2024);
    try std.testing.expect(json.object.get("mes").?.integer == 3);
    try std.testing.expect(json.object.get("día").?.integer == 15);
}

test "AIDA email deliberately aliases the text codec" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings(
        "not-validated-yet",
        try aida_rest.codecs.email.queryToPostgres(arena.allocator(), "not-validated-yet"),
    );
}

test "AIDA REST docente adapter reports the domain business violation" {
    const values = [_]rest.FieldValue{
        .{ .name = "docente", .value = "d1" },
        .{ .name = "apellido", .value = null },
        .{ .name = "nombres", .value = "Ada" },
        .{ .name = "cargo", .value = "teorico" },
        .{ .name = "email", .value = null },
        .{ .name = "email_alternativo", .value = null },
        .{ .name = "jefe", .value = null },
        .{ .name = "telefono", .value = null },
        .{ .name = "experiencia", .value = "4" },
    };

    const violation = (try aida_rest.business_validators.docentes.validate(&values)).?;
    try std.testing.expectEqualStrings("teorico_requires_five_years_experience", violation.code);
}
