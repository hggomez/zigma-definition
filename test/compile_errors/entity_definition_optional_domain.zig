const zigma = @import("zigma");

// Debe fallar en entityDefinition, sin construir Entity ni Framework.
comptime {
    _ = zigma.entityDefinition(.{ .integer = .{ .Type = i64 }, .optional_integer = .{ .Type = ?i64 } }, .{
        .fields = .{ .id = .{ .type = "integer" } },
        .pk = .{"id"},
    });
}
