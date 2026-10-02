//! Tests for the generation of `check.ts`: the restrictions of each entity,
//! derived from the Zig types, for the TS side to check every value that
//! enters it (HTTP -> TS now, HTTP -> frontend later) against the real
//! restriction of Zig. Drives `ts_check_generator.zig`; the generic `check`
//! that walks a description is tested from Node (test/ts_check_test.zig).
//!
//! Per field: its TS type (`tsType`: "string", "number", "bigint",
//! "boolean"; a struct is an "object" with its fields), for an integer the
//! range of its Zig type (`std.math.minInt` / `maxInt`), and `nullable: true`
//! only when the field is nullable and not part of the pk.

const std = @import("std");
const zigma = @import("zigma");
const ts = @import("ts_check_generator");
const expectEqualStrings = std.testing.expectEqualStrings;

const Punto = struct { x: i16, y: u16 };
const type_defs = zigma.defineTypes(zigma.merge(.{ zigma.common_type_defs, .{
    .porcentaje = zigma.TypeDef{ .Type = u8 },
    .punto = zigma.TypeDef{ .Type = Punto },
} }));

// medicion: one field of each kind; `id` is the pk (never null), `valor` is
// not nullable, the rest keep the nullable default.
const medicion = zigma.defineEntity(.{
    .pk = .{"id"},
    .fields = zigma.record(type_defs, .{
        .id = .{ .type = "text" },
        .valor = .{ .type = "integer", .nullable = false },
        .activo = .{ .type = "boolean" },
        .porcentaje = .{ .type = "porcentaje" },
        .lugar = .{ .type = "punto" },
    }),
});

// Same comptime-scope trick as the other generator tests.
const medicion_restrictions_ts = ts.restrictionsFn(type_defs, "medicion", zigma.completeEntity(medicion));

test "restrictionsFn: each field's TS type, the range of its Zig integer type, and nullable only where it can be null" {
    try expectEqualStrings(
        \\export const medicionRestrictions: Record<string, Restriction> = {
        \\  id: { type: "string" },
        \\  valor: { type: "bigint", min: -9223372036854775808n, max: 9223372036854775807n },
        \\  activo: { type: "boolean", nullable: true },
        \\  porcentaje: { type: "number", min: 0, max: 255, nullable: true },
        \\  lugar: { type: "object", fields: { x: { type: "number", min: -32768, max: 32767 }, y: { type: "number", min: 0, max: 65535 } }, nullable: true },
        \\};
    , medicion_restrictions_ts);
}

const una_entidad = zigma.defineEntities(.{ .medicion = medicion });
const check_module_ts = ts.generateTsCheck(type_defs, una_entidad);

test "generateTsCheck: the generic check, then the restrictions of every entity" {
    try expectEqualStrings(ts.check_prelude ++ "\n\n" ++ medicion_restrictions_ts, check_module_ts);
}
