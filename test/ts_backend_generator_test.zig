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

// cosa: one text column, that same column is the pk (all-pk: no update).
const cosa = zigma.defineEntity(.{
    .pk = .{"cosa"},
    .fields = zigma.record(zigma.common_type_defs, .{
        .cosa = .{ .type = "text" },
    }),
});
const cosa_info = zigma.completeEntity(cosa);

// articulo: single pk column + one non-pk column (exercises update).
const articulo = zigma.defineEntity(.{
    .pk = .{"sku"},
    .fields = zigma.record(zigma.common_type_defs, .{
        .sku = .{ .type = "text" },
        .nombre = .{ .type = "text" },
    }),
});
const articulo_info = zigma.completeEntity(articulo);

// combo: composite pk (a, b) + one non-pk column (exercises the pk WHERE
// clause and the SET-then-WHERE placeholder numbering with more than one key).
const combo = zigma.defineEntity(.{
    .pk = .{ "a", "b" },
    .fields = zigma.record(zigma.common_type_defs, .{
        .a = .{ .type = "text" },
        .b = .{ .type = "text" },
        .detalle = .{ .type = "text" },
    }),
});
const combo_info = zigma.completeEntity(combo);

// Same comptime-scope trick as sql_generator_test: each generation call is a
// container-level const so its result stays comptime-known when read from the
// runtime test body below.

// ---- insert ----

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

// ---- selectByPk ----

const cosa_select_by_pk_ts = ts.selectByPkFn(minimal_ts_types, "cosa", cosa_info);

test "selectByPkFn: SELECT * ... WHERE the single pk column" {
    try expectEqualStrings(
        \\export function selectCosaByPk(pk: { cosa: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'SELECT * FROM "cosa" WHERE "cosa" = $1',
        \\    values: [pk.cosa],
        \\  };
        \\}
    , cosa_select_by_pk_ts);
}

const combo_select_by_pk_ts = ts.selectByPkFn(minimal_ts_types, "combo", combo_info);

test "selectByPkFn: composite pk -> WHERE a = $1 AND b = $2, in pk order" {
    try expectEqualStrings(
        \\export function selectComboByPk(pk: { a: string, b: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'SELECT * FROM "combo" WHERE "a" = $1 AND "b" = $2',
        \\    values: [pk.a, pk.b],
        \\  };
        \\}
    , combo_select_by_pk_ts);
}

const cosa_select_by_pk_test_ts = ts.selectByPkFnTest(minimal_ts_samples, "cosa", cosa_info);

test "selectByPkFnTest: a TS test that the selectByPk builder runs and returns a query object" {
    try expectEqualStrings(
        \\test("selectCosaByPk: returns a { text, values } query object", () => {
        \\  const q = selectCosaByPk({ cosa: "s1" });
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
    , cosa_select_by_pk_test_ts);
}

// ---- selectAll ----

const cosa_select_all_ts = ts.selectAllFn("cosa");

test "selectAllFn: SELECT * FROM the entity, no parameters" {
    try expectEqualStrings(
        \\export function selectAllCosa(): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'SELECT * FROM "cosa"',
        \\    values: [],
        \\  };
        \\}
    , cosa_select_all_ts);
}

const cosa_select_all_test_ts = ts.selectAllFnTest("cosa");

test "selectAllFnTest: a TS test that the selectAll builder runs and returns a query object" {
    try expectEqualStrings(
        \\test("selectAllCosa: returns a { text, values } query object", () => {
        \\  const q = selectAllCosa();
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
    , cosa_select_all_test_ts);
}

// ---- update ----

const articulo_update_ts = ts.updateFn(minimal_ts_types, "articulo", articulo_info);

test "updateFn: SET every non-pk column, WHERE the pk, placeholders SET-then-WHERE" {
    try expectEqualStrings(
        \\export function updateArticulo(pk: { sku: string }, row: { nombre: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'UPDATE "articulo" SET "nombre" = $1 WHERE "sku" = $2',
        \\    values: [row.nombre, pk.sku],
        \\  };
        \\}
    , articulo_update_ts);
}

const combo_update_ts = ts.updateFn(minimal_ts_types, "combo", combo_info);

test "updateFn: composite pk -> WHERE placeholders continue after the SET list" {
    try expectEqualStrings(
        \\export function updateCombo(pk: { a: string, b: string }, row: { detalle: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'UPDATE "combo" SET "detalle" = $1 WHERE "a" = $2 AND "b" = $3',
        \\    values: [row.detalle, pk.a, pk.b],
        \\  };
        \\}
    , combo_update_ts);
}

const articulo_update_test_ts = ts.updateFnTest(minimal_ts_samples, "articulo", articulo_info);

test "updateFnTest: a TS test that the update builder runs and returns a query object" {
    try expectEqualStrings(
        \\test("updateArticulo: returns a { text, values } query object", () => {
        \\  const q = updateArticulo({ sku: "s1" }, { nombre: "s1" });
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
    , articulo_update_test_ts);
}

// ---- delete ----

const cosa_delete_ts = ts.deleteFn(minimal_ts_types, "cosa", cosa_info);

test "deleteFn: DELETE ... WHERE the pk" {
    try expectEqualStrings(
        \\export function deleteCosa(pk: { cosa: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'DELETE FROM "cosa" WHERE "cosa" = $1',
        \\    values: [pk.cosa],
        \\  };
        \\}
    , cosa_delete_ts);
}

const cosa_delete_test_ts = ts.deleteFnTest(minimal_ts_samples, "cosa", cosa_info);

test "deleteFnTest: a TS test that the delete builder runs and returns a query object" {
    try expectEqualStrings(
        \\test("deleteCosa: returns a { text, values } query object", () => {
        \\  const q = deleteCosa({ cosa: "s1" });
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
    , cosa_delete_test_ts);
}

// ---- whole-system aggregation ----

// cosa (all-pk: 4 builders, no update) then articulo (5 builders): covers the
// per-entity builder order, the update-skipped branch, and the order between
// entities (declaration order).
const dos_entidades = zigma.defineEntities(.{ .cosa = cosa, .articulo = articulo });
const dos_entidades_ts = ts.generateTsBackend(minimal_ts_types, dos_entidades);

test "generateTsBackend: every builder of every entity, in declaration order" {
    try expectEqualStrings(
        \\export function insertCosa(row: { cosa: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'INSERT INTO "cosa" ("cosa") VALUES ($1)',
        \\    values: [row.cosa],
        \\  };
        \\}
        \\
        \\export function selectCosaByPk(pk: { cosa: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'SELECT * FROM "cosa" WHERE "cosa" = $1',
        \\    values: [pk.cosa],
        \\  };
        \\}
        \\
        \\export function selectAllCosa(): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'SELECT * FROM "cosa"',
        \\    values: [],
        \\  };
        \\}
        \\
        \\export function deleteCosa(pk: { cosa: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'DELETE FROM "cosa" WHERE "cosa" = $1',
        \\    values: [pk.cosa],
        \\  };
        \\}
        \\
        \\export function insertArticulo(row: { sku: string, nombre: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'INSERT INTO "articulo" ("sku", "nombre") VALUES ($1, $2)',
        \\    values: [row.sku, row.nombre],
        \\  };
        \\}
        \\
        \\export function selectArticuloByPk(pk: { sku: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'SELECT * FROM "articulo" WHERE "sku" = $1',
        \\    values: [pk.sku],
        \\  };
        \\}
        \\
        \\export function selectAllArticulo(): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'SELECT * FROM "articulo"',
        \\    values: [],
        \\  };
        \\}
        \\
        \\export function updateArticulo(pk: { sku: string }, row: { nombre: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'UPDATE "articulo" SET "nombre" = $1 WHERE "sku" = $2',
        \\    values: [row.nombre, pk.sku],
        \\  };
        \\}
        \\
        \\export function deleteArticulo(pk: { sku: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'DELETE FROM "articulo" WHERE "sku" = $1',
        \\    values: [pk.sku],
        \\  };
        \\}
    , dos_entidades_ts);
}

const dos_entidades_tests_ts = ts.generateTsBackendTests(minimal_ts_samples, dos_entidades);

test "generateTsBackendTests: imports plus the generated test for every builder, in declaration order" {
    try expectEqualStrings(
        \\import { test } from "node:test";
        \\import assert from "node:assert/strict";
        \\
        \\import { insertCosa, selectCosaByPk, selectAllCosa, deleteCosa, insertArticulo, selectArticuloByPk, selectAllArticulo, updateArticulo, deleteArticulo } from "./dml.ts";
        \\
        \\test("insertCosa: returns a { text, values } query object", () => {
        \\  const q = insertCosa({ cosa: "s1" });
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
        \\
        \\test("selectCosaByPk: returns a { text, values } query object", () => {
        \\  const q = selectCosaByPk({ cosa: "s1" });
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
        \\
        \\test("selectAllCosa: returns a { text, values } query object", () => {
        \\  const q = selectAllCosa();
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
        \\
        \\test("deleteCosa: returns a { text, values } query object", () => {
        \\  const q = deleteCosa({ cosa: "s1" });
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
        \\
        \\test("insertArticulo: returns a { text, values } query object", () => {
        \\  const q = insertArticulo({ sku: "s1", nombre: "s1" });
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
        \\
        \\test("selectArticuloByPk: returns a { text, values } query object", () => {
        \\  const q = selectArticuloByPk({ sku: "s1" });
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
        \\
        \\test("selectAllArticulo: returns a { text, values } query object", () => {
        \\  const q = selectAllArticulo();
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
        \\
        \\test("updateArticulo: returns a { text, values } query object", () => {
        \\  const q = updateArticulo({ sku: "s1" }, { nombre: "s1" });
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
        \\
        \\test("deleteArticulo: returns a { text, values } query object", () => {
        \\  const q = deleteArticulo({ sku: "s1" });
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
    , dos_entidades_tests_ts);
}
