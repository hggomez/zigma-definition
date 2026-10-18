//! Se espera un rechazo: los ciclos de claves foráneas entre tablas
//! requieren una fase posterior de ALTER TABLE.
const zigma = @import("zigma");
const ddl = @import("zigma_postgres_ddl");

comptime {
    const left_fields = zigma.record(zigma.common_type_defs, .{
        .left = .{ .type = "text" },
        .right = .{ .type = "text" },
    });
    const right_fields = zigma.record(zigma.common_type_defs, .{
        .right = .{ .type = "text" },
        .left = .{ .type = "text" },
    });
    const lefts = .{
        .pk = .{"left"},
        .fks = .{ .rights = .{ .entity = "rights", .fields = .{"right"} } },
        .fields = left_fields,
    };
    const rights = .{
        .pk = .{"right"},
        .fks = .{ .lefts = .{ .entity = "lefts", .fields = .{"left"} } },
        .fields = right_fields,
    };
    const entities = zigma.defineEntities(.{ .lefts = .{ .Type = zigma.Entity(zigma.common_type_defs, lefts), .definition = lefts }, .rights = .{ .Type = zigma.Entity(zigma.common_type_defs, rights), .definition = rights } });
    const Model = zigma.Framework(zigma.common_type_defs, entities);
    _ = ddl.createSchemaDdl(Model, ddl.common_type_mappings);
}
