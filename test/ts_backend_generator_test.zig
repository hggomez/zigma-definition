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

const cosa_insert_ts = ts.insertFn(zigma.common_type_defs, "cosa", cosa_info);

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

const cosa_insert_test_ts = ts.insertFnTest(zigma.common_type_defs, "cosa", cosa_info);

test "insertFnTest: a TS test that the insert builder runs and returns a query object" {
    try expectEqualStrings(
        \\test("insertCosa: returns a { text, values } query object", () => {
        \\  const q = insertCosa({ cosa: "s1" });
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
    , cosa_insert_test_ts);
}

// muestra: one field of each kind of Zig type behind a domain (slice, i64,
// bool, struct), to check the sample literal derived from each type.
const Punto = struct { x: i16, y: u16 };
const muestra_type_defs = zigma.defineTypes(zigma.merge(.{ zigma.common_type_defs, .{
    .punto = zigma.TypeDef{ .Type = Punto },
} }));
const muestra = zigma.defineEntity(.{
    .pk = .{"id"},
    .fields = zigma.record(muestra_type_defs, .{
        .id = .{ .type = "text" },
        .cantidad = .{ .type = "integer" },
        .activo = .{ .type = "boolean" },
        .ubicacion = .{ .type = "punto" },
    }),
});
const muestra_insert_test_ts = ts.insertFnTest(muestra_type_defs, "muestra", zigma.completeEntity(muestra));

test "insertFnTest: the sample literal of each field is derived from its Zig type" {
    // i64 is a TS bigint, hence 1n; a struct is an object literal, one sample
    // per field.
    try expectEqualStrings(
        \\test("insertMuestra: returns a { text, values } query object", () => {
        \\  const q = insertMuestra({ id: "s1", cantidad: 1n, activo: true, ubicacion: { x: 1, y: 1 } });
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
    , muestra_insert_test_ts);
}

// ---- selectByPk ----

const cosa_select_by_pk_ts = ts.selectByPkFn(zigma.common_type_defs, "cosa", cosa_info);

test "selectByPkFn: SELECT <columns> ... WHERE the single pk column" {
    try expectEqualStrings(
        \\export function selectCosaByPk(pk: { cosa: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'SELECT "cosa" FROM "cosa" WHERE "cosa" = $1',
        \\    values: [pk.cosa],
        \\  };
        \\}
    , cosa_select_by_pk_ts);
}

const combo_select_by_pk_ts = ts.selectByPkFn(zigma.common_type_defs, "combo", combo_info);

test "selectByPkFn: composite pk -> WHERE a = $1 AND b = $2, in pk order" {
    try expectEqualStrings(
        \\export function selectComboByPk(pk: { a: string, b: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'SELECT "a", "b", "detalle" FROM "combo" WHERE "a" = $1 AND "b" = $2',
        \\    values: [pk.a, pk.b],
        \\  };
        \\}
    , combo_select_by_pk_ts);
}

const cosa_select_by_pk_test_ts = ts.selectByPkFnTest(zigma.common_type_defs, "cosa", cosa_info);

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

const cosa_select_all_ts = ts.selectAllFn(zigma.common_type_defs, "cosa", cosa_info);

test "selectAllFn: SELECT <columns> FROM the entity, no parameters" {
    try expectEqualStrings(
        \\export function selectAllCosa(): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'SELECT "cosa" FROM "cosa"',
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

const articulo_update_ts = ts.updateFn(zigma.common_type_defs, "articulo", articulo_info);

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

const combo_update_ts = ts.updateFn(zigma.common_type_defs, "combo", combo_info);

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

const articulo_update_test_ts = ts.updateFnTest(zigma.common_type_defs, "articulo", articulo_info);

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

const cosa_delete_ts = ts.deleteFn(zigma.common_type_defs, "cosa", cosa_info);

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

const cosa_delete_test_ts = ts.deleteFnTest(zigma.common_type_defs, "cosa", cosa_info);

test "deleteFnTest: a TS test that the delete builder runs and returns a query object" {
    try expectEqualStrings(
        \\test("deleteCosa: returns a { text, values } query object", () => {
        \\  const q = deleteCosa({ cosa: "s1" });
        \\  assert.equal(typeof q.text, "string");
        \\  assert.ok(Array.isArray(q.values));
        \\});
    , cosa_delete_test_ts);
}

// ---- struct-backed columns: the codec lives in the SQL text ----
//
// Encode: one parameter per leaf field, the composite assembled with
// ROW(...)::<type> (explicit casts so Postgres infers the parameter types);
// a nullable column wraps it in CASE WHEN <every field> IS NULL (ROW(NULL,
// NULL) is not NULL): only a struct with no field at all is NULL, a partial
// one becomes a ROW that the `<entity>_<column>_complete` CHECK of the table
// rejects. Decode: to_jsonb(<column>) in the SELECT list, which pg already
// turns into a JS object.

// lugar: a nullable struct column outside the pk (`ubicacion`).
const lugar = zigma.defineEntity(.{
    .pk = .{"lugar"},
    .fields = zigma.record(muestra_type_defs, .{
        .lugar = .{ .type = "text" },
        .ubicacion = .{ .type = "punto" },
    }),
});
const lugar_info = zigma.completeEntity(lugar);
const lugar_insert_ts = ts.insertFn(muestra_type_defs, "lugar", lugar_info);
const lugar_select_by_pk_ts = ts.selectByPkFn(muestra_type_defs, "lugar", lugar_info);
const lugar_select_all_ts = ts.selectAllFn(muestra_type_defs, "lugar", lugar_info);
const lugar_update_ts = ts.updateFn(muestra_type_defs, "lugar", lugar_info);

test "insertFn: a nullable struct column is encoded as CASE/ROW over one parameter per field" {
    try expectEqualStrings(
        \\export function insertLugar(row: { lugar: string, ubicacion: { x: number; y: number } }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'INSERT INTO "lugar" ("lugar", "ubicacion") VALUES ($1, CASE WHEN $2::SMALLINT IS NULL AND $3::zig_u16 IS NULL THEN NULL ELSE ROW($2::SMALLINT, $3::zig_u16)::punto END)',
        \\    values: [row.lugar, row.ubicacion?.x ?? null, row.ubicacion?.y ?? null],
        \\  };
        \\}
    , lugar_insert_ts);
}

test "selectByPkFn: a struct column is decoded with to_jsonb" {
    try expectEqualStrings(
        \\export function selectLugarByPk(pk: { lugar: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'SELECT "lugar", to_jsonb("ubicacion") AS "ubicacion" FROM "lugar" WHERE "lugar" = $1',
        \\    values: [pk.lugar],
        \\  };
        \\}
    , lugar_select_by_pk_ts);
}

test "selectAllFn: a struct column is decoded with to_jsonb" {
    try expectEqualStrings(
        \\export function selectAllLugar(): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'SELECT "lugar", to_jsonb("ubicacion") AS "ubicacion" FROM "lugar"',
        \\    values: [],
        \\  };
        \\}
    , lugar_select_all_ts);
}

test "updateFn: a struct column in SET takes one placeholder per field, the WHERE ones follow" {
    try expectEqualStrings(
        \\export function updateLugar(pk: { lugar: string }, row: { ubicacion: { x: number; y: number } }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'UPDATE "lugar" SET "ubicacion" = CASE WHEN $1::SMALLINT IS NULL AND $2::zig_u16 IS NULL THEN NULL ELSE ROW($1::SMALLINT, $2::zig_u16)::punto END WHERE "lugar" = $3',
        \\    values: [row.ubicacion?.x ?? null, row.ubicacion?.y ?? null, pk.lugar],
        \\  };
        \\}
    , lugar_update_ts);
}

// marca: a struct column that is the pk (`punto`, never NULL: plain ROW, no
// CASE), plus one non-pk column.
const marca = zigma.defineEntity(.{
    .pk = .{"punto"},
    .fields = zigma.record(muestra_type_defs, .{
        .punto = .{ .type = "punto" },
        .nombre = .{ .type = "text" },
    }),
});
const marca_info = zigma.completeEntity(marca);
const marca_insert_ts = ts.insertFn(muestra_type_defs, "marca", marca_info);
const marca_select_by_pk_ts = ts.selectByPkFn(muestra_type_defs, "marca", marca_info);
const marca_update_ts = ts.updateFn(muestra_type_defs, "marca", marca_info);
const marca_delete_ts = ts.deleteFn(muestra_type_defs, "marca", marca_info);

test "insertFn: a pk struct column is encoded as a plain ROW" {
    try expectEqualStrings(
        \\export function insertMarca(row: { punto: { x: number; y: number }, nombre: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'INSERT INTO "marca" ("punto", "nombre") VALUES (ROW($1::SMALLINT, $2::zig_u16)::punto, $3)',
        \\    values: [row.punto.x, row.punto.y, row.nombre],
        \\  };
        \\}
    , marca_insert_ts);
}

test "selectByPkFn: a struct pk is compared against a ROW, independent of the key order of the object" {
    try expectEqualStrings(
        \\export function selectMarcaByPk(pk: { punto: { x: number; y: number } }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'SELECT to_jsonb("punto") AS "punto", "nombre" FROM "marca" WHERE "punto" = ROW($1::SMALLINT, $2::zig_u16)::punto',
        \\    values: [pk.punto.x, pk.punto.y],
        \\  };
        \\}
    , marca_select_by_pk_ts);
}

test "updateFn: a struct pk in WHERE continues the numbering after the SET" {
    try expectEqualStrings(
        \\export function updateMarca(pk: { punto: { x: number; y: number } }, row: { nombre: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'UPDATE "marca" SET "nombre" = $1 WHERE "punto" = ROW($2::SMALLINT, $3::zig_u16)::punto',
        \\    values: [row.nombre, pk.punto.x, pk.punto.y],
        \\  };
        \\}
    , marca_update_ts);
}

test "deleteFn: a struct pk is compared against a ROW" {
    try expectEqualStrings(
        \\export function deleteMarca(pk: { punto: { x: number; y: number } }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'DELETE FROM "marca" WHERE "punto" = ROW($1::SMALLINT, $2::zig_u16)::punto',
        \\    values: [pk.punto.x, pk.punto.y],
        \\  };
        \\}
    , marca_delete_ts);
}

// ---- pg type parsers ----

// Columns whose TS type needs a parser on read (i64 -> BIGINT -> bigint: pg
// returns BIGINT as a string by default). Generated from the framework's
// `zig_type_map_ts.ts_parser_defs`; per pool, not global:
// `new pg.Pool({ types: pgTypes(pg.types) })`.
const pg_types_ts = ts.pgTypesFn();

test "pgTypesFn: a per-pool getTypeParser with the framework's parsers, falling back to pg's defaults" {
    try expectEqualStrings(
        \\export function pgTypes(defaults: { getTypeParser(oid: number, format?: string): unknown }) {
        \\  const parsers: Record<number, (value: string) => unknown> = {
        \\    20: BigInt,
        \\  };
        \\  return {
        \\    getTypeParser(oid: number, format?: string) {
        \\      return parsers[oid] ?? defaults.getTypeParser(oid, format);
        \\    },
        \\  };
        \\}
    , pg_types_ts);
}

// ---- domain errors ----

// A pk/uk/fk violation comes from pg as `{ code, constraint }`: 23505
// (unique_violation, pk or uk) or 23503 (foreign_key_violation). The DDL names
// every constraint from the SSOT (`<entity>_pk`, `<entity>_uk_<uk>`,
// `<entity>_fk_<fk>`), so `domainError` maps the name back to the entity and
// key of the definition through a lookup table generated from `entity_defs`;
// any other error is not a domain error (null).
const categoria = zigma.defineEntity(.{
    .pk = .{"categoria"},
    .uks = .{ .nombre = .{"nombre"} },
    .fields = zigma.record(zigma.common_type_defs, .{
        .categoria = .{ .type = "text" },
        .nombre = .{ .type = "text" },
    }),
});
const producto = zigma.defineEntity(.{
    .pk = .{"sku"},
    .fks = .{ .categoria = .{ .entity = "categoria", .fields = categoria.pk } },
    .fields = zigma.record(zigma.common_type_defs, .{
        .sku = .{ .type = "text" },
        .categoria = .{ .type = "text" },
    }),
});
const tienda = zigma.defineEntities(.{ .categoria = categoria, .producto = producto });
const tienda_domain_error_ts = ts.domainErrorFn(tienda);

test "domainErrorFn: maps each named pk/uk/fk constraint of the system to its entity and key" {
    try expectEqualStrings(
        \\export type DomainError =
        \\  | { kind: "pk_violation"; entity: string }
        \\  | { kind: "uk_violation" | "fk_violation"; entity: string; key: string };
        \\
        \\const domainConstraints: Record<string, DomainError> = {
        \\  "categoria_pk": { kind: "pk_violation", entity: "categoria" },
        \\  "categoria_uk_nombre": { kind: "uk_violation", entity: "categoria", key: "nombre" },
        \\  "producto_pk": { kind: "pk_violation", entity: "producto" },
        \\  "producto_fk_categoria": { kind: "fk_violation", entity: "producto", key: "categoria" },
        \\};
        \\
        \\export function domainError(err: unknown): DomainError | null {
        \\  const { code, constraint } = (err ?? {}) as { code?: unknown; constraint?: unknown };
        \\  if (code !== "23505" && code !== "23503") return null;
        \\  if (typeof constraint !== "string" || !Object.hasOwn(domainConstraints, constraint)) return null;
        \\  return domainConstraints[constraint];
        \\}
    , tienda_domain_error_ts);
}

// ---- whole-system aggregation ----

// cosa (all-pk: 4 builders, no update) then articulo (5 builders): covers the
// per-entity builder order, the update-skipped branch, and the order between
// entities (declaration order).
const dos_entidades = zigma.defineEntities(.{ .cosa = cosa, .articulo = articulo });
const dos_entidades_ts = ts.generateTsBackend(zigma.common_type_defs, dos_entidades);

test "generateTsBackend: pgTypes, domainError, then every builder of every entity, in declaration order" {
    try expectEqualStrings(
        \\export function pgTypes(defaults: { getTypeParser(oid: number, format?: string): unknown }) {
        \\  const parsers: Record<number, (value: string) => unknown> = {
        \\    20: BigInt,
        \\  };
        \\  return {
        \\    getTypeParser(oid: number, format?: string) {
        \\      return parsers[oid] ?? defaults.getTypeParser(oid, format);
        \\    },
        \\  };
        \\}
        \\
        \\export type DomainError =
        \\  | { kind: "pk_violation"; entity: string }
        \\  | { kind: "uk_violation" | "fk_violation"; entity: string; key: string };
        \\
        \\const domainConstraints: Record<string, DomainError> = {
        \\  "cosa_pk": { kind: "pk_violation", entity: "cosa" },
        \\  "articulo_pk": { kind: "pk_violation", entity: "articulo" },
        \\};
        \\
        \\export function domainError(err: unknown): DomainError | null {
        \\  const { code, constraint } = (err ?? {}) as { code?: unknown; constraint?: unknown };
        \\  if (code !== "23505" && code !== "23503") return null;
        \\  if (typeof constraint !== "string" || !Object.hasOwn(domainConstraints, constraint)) return null;
        \\  return domainConstraints[constraint];
        \\}
        \\
        \\export function insertCosa(row: { cosa: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'INSERT INTO "cosa" ("cosa") VALUES ($1)',
        \\    values: [row.cosa],
        \\  };
        \\}
        \\
        \\export function selectCosaByPk(pk: { cosa: string }): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'SELECT "cosa" FROM "cosa" WHERE "cosa" = $1',
        \\    values: [pk.cosa],
        \\  };
        \\}
        \\
        \\export function selectAllCosa(): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'SELECT "cosa" FROM "cosa"',
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
        \\    text: 'SELECT "sku", "nombre" FROM "articulo" WHERE "sku" = $1',
        \\    values: [pk.sku],
        \\  };
        \\}
        \\
        \\export function selectAllArticulo(): { text: string; values: unknown[] } {
        \\  return {
        \\    text: 'SELECT "sku", "nombre" FROM "articulo"',
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

const dos_entidades_tests_ts = ts.generateTsBackendTests(zigma.common_type_defs, dos_entidades);

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
