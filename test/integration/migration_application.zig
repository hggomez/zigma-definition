//! Proyección PostgreSQL de un consumidor independiente de AIDA.
//! Solo publica los dos valores que necesita la herramienta de migraciones.

const zigma = @import("zigma");
const ddl = @import("zigma_postgres_ddl");
const migrations = @import("zigma_postgres_migrations");
const options = @import("fixture_options");

const fields = if (options.extended)
    zigma.record(zigma.common_type_defs, .{
        .id = .{ .type = "integer" },
        .name = .{ .type = "text", .nullable = false },
        .note = .{ .type = "text", .nullable = true },
    })
else
    zigma.record(zigma.common_type_defs, .{
        .id = .{ .type = "integer" },
        .name = .{ .type = "text", .nullable = false },
    });

const definition = .{ .fields = fields, .pk = .{"id"} };
const entity_defs = zigma.defineEntities(.{
    .products = .{
        .Type = zigma.Entity(zigma.common_type_defs, definition),
        .definition = definition,
    },
});
const Model = zigma.Framework(zigma.common_type_defs, entity_defs);

pub const schema_snapshot = migrations.createSchemaSnapshot(Model, ddl.common_type_mappings);
pub const baseline_ddl = ddl.createBaselineDdl(Model, ddl.common_type_mappings);
