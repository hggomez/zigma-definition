//! Proyección PostgreSQL de la definición de AIDA, independiente de la base de datos.

const zigma = @import("zigma");
const aida = @import("aida");
const postgres_ddl = @import("zigma_postgres_ddl");
const postgres_migrations = @import("zigma_postgres_migrations");

// Proyección específica de PostgreSQL de nombres de dominio independientes de la
// base de datos. `merge` produce un único struct anónimo y la validación comprueba
// en compilación que cada mapping tenga un tipo SQL utilizable.
pub const type_mappings = postgres_ddl.defineTypeMappings(zigma.merge(.{
    postgres_ddl.common_type_mappings,
    .{
        .fecha = postgres_ddl.TypeMapping{ .sql_type = "DATE" },
        .email = postgres_ddl.TypeMapping{ .sql_type = "TEXT" },
    },
}));

// Los dos artefactos siguientes son strings comptime derivados de las mismas
// entidades y mappings. Tienen distintos propósitos: JSON es el modelo aceptado
// para comparar; SQL crea un schema físico nuevo.
pub const schema_snapshot = postgres_migrations.createSchemaSnapshot(
    aida.Model,
    type_mappings,
);

pub const baseline_ddl = postgres_ddl.createBaselineDdl(
    aida.Model,
    type_mappings,
);
