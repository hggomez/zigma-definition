const contract = @import("contract");
const ddl = @import("zigma_postgres_ddl");
const migrations = @import("zigma_postgres_migrations");

pub const schema_snapshot = migrations.createSchemaSnapshot(contract.Model, ddl.common_type_mappings);
pub const baseline_ddl = ddl.createBaselineDdl(contract.Model, ddl.common_type_mappings);
