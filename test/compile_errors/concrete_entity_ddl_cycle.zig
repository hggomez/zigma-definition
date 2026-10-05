const ddl = @import("zigma_postgres_ddl");
const contract = @import("fixtures/concrete_entities.zig");
comptime {
    _ = ddl.createSchemaDdl(contract.CircularModel, ddl.common_type_mappings);
}
