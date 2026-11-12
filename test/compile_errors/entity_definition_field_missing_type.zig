const zigma = @import("zigma");

// Debe fallar en entityDefinition, sin construir Entity ni Framework.
comptime {
    _ = zigma.entityDefinition(zigma.common_type_defs, .{
        .fields = .{ .id = .{ .nullable = false } },
        .pk = .{"id"},
    });
}
