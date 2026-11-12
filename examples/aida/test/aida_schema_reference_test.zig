//! Referencias independientes del modelo normalizado, actualizadas con el contrato AIDA.
//! Cambiar la implementación de los generadores no debe cambiar estos bytes.
const std = @import("std");
const postgres = @import("aida_postgres");

test "El DDL inicial de AIDA coincide con su referencia independiente" {
    try std.testing.expectEqualStrings(
        @embedFile("fixtures/aida-baseline-before-model.sql"),
        postgres.baseline_ddl,
    );
}

test "El snapshot de AIDA coincide con su referencia independiente" {
    try std.testing.expectEqualStrings(
        @embedFile("fixtures/aida-snapshot-before-model.json"),
        postgres.schema_snapshot,
    );
}
