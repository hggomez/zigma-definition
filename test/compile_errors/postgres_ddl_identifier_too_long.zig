//! Se espera un rechazo: los identificadores PostgreSQL tienen un límite de 63 bytes.
const zigma = @import("zigma");
const ddl = @import("zigma_postgres_ddl");

comptime {
    const fields = zigma.record(zigma.common_type_defs, .{
        .aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa = .{ .type = "text" },
    });
    const entity = zigma.defineEntity(.{
        .pk = .{"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
        .fields = fields,
    });
    const entities = zigma.defineEntities(.{ .things = entity });
    const Model = zigma.System(zigma.common_type_defs, entities);
    _ = ddl.createTableDdl(Model, "things", ddl.common_type_mappings);
}
