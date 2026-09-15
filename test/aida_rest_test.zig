const std = @import("std");
const aida_rest = @import("aida_rest");
const rest = @import("zigma_rest");

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
