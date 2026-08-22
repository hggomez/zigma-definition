//! expected: missing PostgreSQL type mapping for domain type 'fecha'
const ddl = @import("zigma_postgres_ddl");
const aida = @import("aida");

comptime {
    _ = ddl.createTableDdl(aida.entity_defs, "clases", ddl.common_type_mappings);
}
