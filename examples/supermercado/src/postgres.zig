//! Proyección PostgreSQL del supermercado, independiente de conexiones e historial.
const zigma = @import("zigma");
const contract = @import("contract");
const ddl = @import("zigma_postgres_ddl");
const migrations = @import("zigma_postgres_migrations");

pub const type_mappings = ddl.defineTypeMappings(zigma.merge(.{
    ddl.common_type_mappings,
    .{
        .importe = ddl.TypeMapping{ .sql_type = "BIGINT" },
        .instante = ddl.TypeMapping{ .sql_type = "TIMESTAMPTZ" },
    },
}));

pub const schema_snapshot = migrations.createSchemaSnapshot(contract.Model, type_mappings);
pub const baseline_ddl = ddl.createBaselineDdl(contract.Model, type_mappings);
