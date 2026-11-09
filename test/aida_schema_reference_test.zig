//! Referencias independientes del modelo normalizado, actualizadas con el contrato AIDA.
//! Cambiar la implementación de los generadores no debe cambiar estos bytes.
const std = @import("std");
const postgres = @import("aida_postgres");

test "AIDA baseline DDL matches its independent reference" {
    try std.testing.expectEqualStrings(
        @embedFile("fixtures/aida-baseline-before-model.sql"),
        postgres.baseline_ddl,
    );
}

test "AIDA snapshot matches its independent reference" {
    try std.testing.expectEqualStrings(
        @embedFile("fixtures/aida-snapshot-before-model.json"),
        postgres.schema_snapshot,
    );
}
