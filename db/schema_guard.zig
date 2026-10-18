const postgres = @import("aida_postgres");
const migrations = @import("zigma_postgres_migrations");

// @embedFile incorpora el snapshot histórico revisado a la compilación, evita
// acceder al filesystem en runtime y hace reproducible la comparación.
const accepted_snapshot = @embedFile("schema.snapshot.json");

comptime {
    // Si las entidades o mappings actuales difieren, la compilación se detiene
    // y dirige al desarrollador al flujo explícito de crear, revisar y aceptar el draft.
    migrations.assertAcceptedSnapshot(
        @import("aida").Model,
        postgres.type_mappings,
        accepted_snapshot,
    );
}
