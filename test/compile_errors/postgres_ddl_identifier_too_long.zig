//! expected: PostgreSQL identifiers are limited to 63 bytes
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
    _ = ddl.createTableDdl(entities, "things", ddl.common_type_mappings);
}
