//! Referencias capturadas antes de implementar el modelo normalizado.
//! Cambiar las firmas de las APIs no debe cambiar estos bytes.
const std = @import("std");
const postgres = @import("aida_postgres");

test "AIDA baseline DDL remains byte-identical to its pre-model reference" {
    try std.testing.expectEqualStrings(
        @embedFile("fixtures/aida-baseline-before-model.sql"),
        postgres.baseline_ddl,
    );
}

test "AIDA snapshot remains byte-identical to its pre-model reference" {
    try std.testing.expectEqualStrings(
        @embedFile("fixtures/aida-snapshot-before-model.json"),
        postgres.schema_snapshot,
    );
}
