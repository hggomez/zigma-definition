const zigma = @import("zigma");

// La comprobación del destino corresponde al registro, no a entityDefinition.
comptime {
    const definition = zigma.entityDefinition(zigma.common_type_defs, .{
        .fields = .{ .id = .{ .type = "integer" } },
        .pk = .{"id"},
        .fks = .{ .parent = .{ .entity = "missing", .fields = .{"id"} } },
    });
    _ = zigma.defineEntities(.{
        .items = .{ .Type = zigma.Entity(zigma.common_type_defs, definition), .definition = definition },
    });
}
