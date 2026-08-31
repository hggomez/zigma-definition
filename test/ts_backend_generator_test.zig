//! Tests for TypeScript DML entry-point generation from zigma EntityInfo,
//! driving the implementation of `ts_backend_generator.zig`. Same fixture
//! conventions as `sql_generator_test.zig`: ad-hoc entities for the minimal
//! base-format cases, `aida` entities once a test exercises a pattern the
//! vocabulary already has (composite pk, fks, every domain type, ...).

const std = @import("std");
const zigma = @import("zigma");
const aida = @import("aida");
const ts = @import("ts_backend_generator");
const expectEqualStrings = std.testing.expectEqualStrings;

const minimal_ts_types = .{ .text = "string" };
const minimal_ts_samples = .{ .text = "\"s1\"" };

const cosa = zigma.defineEntity(.{
    .pk = .{"cosa"},
    .fields = zigma.record(zigma.common_type_defs, .{
        .cosa = .{ .type = "text" },
    }),
});

// Same comptime-scope trick as sql_generator_test: the generation call is a
// container-level const so its result stays comptime-known when read from the
// runtime test body below.
const cosa_info = zigma.completeEntity(cosa);
const cosa_insert_ts = ts.insertFn(minimal_ts_types, "cosa", cosa_info);

test "insertFn: a typed INSERT builder for an entity with one column" {
    try expectEqualStrings(
        \\export function insertCosa(row: { cosa: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'INSERT INTO "cosa" ("cosa") VALUES ($1)',
        \\    values: [row.cosa],
        \\  };
        \\}
    , cosa_insert_ts);
}

// The generator also emits the TS test that exercises the generated code in
// Node - the layer a Zig string-assert can't reach (does the emitted TS
// parse, type-check and run). #1 of the test menu: call the builder, it does
// not throw, it returns a `{ text, values }` query object. The sample row
// value comes from a TS-type -> sample-literal map (`text` -> `"s1"`).
const cosa_insert_test_ts = ts.insertFnTest(minimal_ts_samples, "cosa", cosa_info);

test "insertFnTest: a TS test that the insert builder runs and returns a query object" {
    try expectEqualStrings(
        \\test("insertCosa: returns a { text, values } query object", () => {
        \\  const q = insertCosa({ cosa: "s1" });
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
    , cosa_insert_test_ts);
}

const otra = zigma.defineEntity(.{
    .pk = .{"otra"},
    .fields = zigma.record(zigma.common_type_defs, .{
        .otra = .{ .type = "text" },
    }),
});

// cosa and otra are independent (no fk between them): this checks only the
// whole-module aggregation, one insert builder per entity in declaration order.
const dos_entidades = zigma.defineEntities(.{ .cosa = cosa, .otra = otra });
const dos_entidades_ts = ts.generateTsBackend(minimal_ts_types, dos_entidades);

test "generateTsBackend: one TS module with an insert builder per entity, in declaration order" {
    try expectEqualStrings(
        \\export function insertCosa(row: { cosa: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'INSERT INTO "cosa" ("cosa") VALUES ($1)',
        \\    values: [row.cosa],
        \\  };
        \\}
        \\
        \\export function insertOtra(row: { otra: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'INSERT INTO "otra" ("otra") VALUES ($1)',
        \\    values: [row.otra],
        \\  };
        \\}
    , dos_entidades_ts);
}

// The test module imports the builders from the generated impl module by a
// fixed relative path (`./dml.ts`); the build step that writes both files
// owns that name.
const dos_entidades_tests_ts = ts.generateTsBackendTests(minimal_ts_samples, dos_entidades);

test "generateTsBackendTests: full TS test module, imports plus one test per entity, in declaration order" {
    try expectEqualStrings(
        \\import { test } from "node:test";
        \\import assert from "node:assert/strict";
        \\
        \\import { insertCosa, insertOtra } from "./dml.ts";
        \\
        \\test("insertCosa: returns a { text, values } query object", () => {
        \\  const q = insertCosa({ cosa: "s1" });
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
        \\
        \\test("insertOtra: returns a { text, values } query object", () => {
        \\  const q = insertOtra({ otra: "s1" });
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
    , dos_entidades_tests_ts);
}
