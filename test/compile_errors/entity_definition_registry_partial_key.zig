const zigma = @import("zigma");

// Los campos destino existen, pero no cubren una PK ni una UK completa.
comptime {
    const parent = zigma.entityDefinition(zigma.common_type_defs, .{
        .fields = .{
            .tenant = .{ .type = "text" },
            .id = .{ .type = "integer" },
            .code = .{ .type = "text" },
        },
        .pk = .{ "tenant", "id" },
        .uks = .{ .by_code = .{ "tenant", "code" } },
    });
    const item = zigma.entityDefinition(zigma.common_type_defs, .{
        .fields = .{
            .id = .{ .type = "integer" },
            .tenant = .{ .type = "text" },
        },
        .pk = .{"id"},
        .fks = .{ .parent = .{ .entity = "parents", .fields = .{"tenant"} } },
    });
    _ = zigma.defineEntities(.{
        .parents = .{ .Type = zigma.Entity(zigma.common_type_defs, parent), .definition = parent },
        .items = .{ .Type = zigma.Entity(zigma.common_type_defs, item), .definition = item },
    });
}
