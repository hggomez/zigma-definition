//! expected: cross-table foreign key cycles require a later ALTER TABLE phase
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
    const lefts = zigma.defineEntity(.{
        .pk = .{"left"},
        .fks = .{ .rights = .{ .entity = "rights", .fields = .{"right"} } },
        .fields = left_fields,
    });
    const rights = zigma.defineEntity(.{
        .pk = .{"right"},
        .fks = .{ .lefts = .{ .entity = "lefts", .fields = .{"left"} } },
        .fields = right_fields,
    });
    const entities = zigma.defineEntities(.{ .lefts = lefts, .rights = rights });
    _ = ddl.createSchemaDdl(entities, ddl.common_type_mappings);
}
