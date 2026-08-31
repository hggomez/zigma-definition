const postgres = @import("aida_postgres");
const migrations = @import("zigma_postgres_migrations");

const accepted_snapshot = @embedFile("schema.snapshot.json");

comptime {
    migrations.assertAcceptedSnapshot(
        @import("aida").entity_defs,
        postgres.type_mappings,
        accepted_snapshot,
    );
}

