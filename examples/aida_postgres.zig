//! PostgreSQL projection of the database-agnostic AIDA system definition.

const zigma = @import("zigma");
const aida = @import("aida");
const postgres_ddl = @import("zigma_postgres_ddl");
const postgres_migrations = @import("zigma_postgres_migrations");

pub const type_mappings = postgres_ddl.defineTypeMappings(zigma.merge(.{
    postgres_ddl.common_type_mappings,
    .{
        .fecha = postgres_ddl.TypeMapping{ .sql_type = "DATE" },
        .email = postgres_ddl.TypeMapping{ .sql_type = "TEXT" },
    },
}));

pub const schema_snapshot = postgres_migrations.createSchemaSnapshot(
    aida.entity_defs,
    type_mappings,
);

pub const baseline_ddl = postgres_ddl.createBaselineDdl(
    aida.entity_defs,
    type_mappings,
);
