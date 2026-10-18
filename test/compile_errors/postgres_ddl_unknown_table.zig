//! Diagnóstico esperado: `unknown entity 'inexistentes'`.
const ddl = @import("zigma_postgres_ddl");
const aida = @import("aida");

comptime {
    _ = ddl.createTableDdl(aida.Model, "inexistentes", ddl.common_type_mappings);
}
