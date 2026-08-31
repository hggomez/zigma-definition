const zigma = @import("zigma");
const aida = @import("aida");
const ddl = @import("zigma_postgres_ddl");
const migrations = @import("zigma_postgres_migrations");

const mappings = ddl.defineTypeMappings(zigma.merge(.{
    ddl.common_type_mappings,
    .{
        .fecha = ddl.TypeMapping{ .sql_type = "DATE" },
        .email = ddl.TypeMapping{ .sql_type = "TEXT" },
    },
}));

comptime {
    migrations.assertAcceptedSnapshot(aida.entity_defs, mappings, "{}");
}
