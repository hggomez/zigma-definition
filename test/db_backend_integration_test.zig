//! Integration test for the generated DML builders against the docker-compose
//! Postgres. Unlike the pure string-assert tests, here the database is the
//! oracle: the test drives the *generated* `backend/src/dml.ts` builders
//! through Node and checks the round-trip in the real database.
//!
//! Run with `zig build ts-backend-db`, which first brings up the container,
//! applies the aida schema, runs `npm install` in `backend/`, and regenerates
//! `dml.ts`. Not part of `zig build test` (needs Docker + Node).

const std = @import("std");

// A small ES module run with `node --input-type=module -e`, from `backend/` so
// `./src/dml.ts` and `pg` (in node_modules) both resolve: imports the
// generated builders, does insert -> selectByPk -> assert -> delete, prints
// ROUNDTRIP_OK on success.
const roundtrip_script =
    \\import { insertPeriodos, selectPeriodosByPk, deletePeriodos } from './src/dml.ts';
    \\import pg from 'pg';
    \\const connectionString = process.env.DATABASE_URL ?? 'postgres://aida:aida@localhost:5432/aida';
    \\const pool = new pg.Pool({ connectionString });
    \\const periodo = 'it-' + Date.now();
    \\try {
    \\  let q = insertPeriodos({ periodo });
    \\  await pool.query(q.text, q.values);
    \\  q = selectPeriodosByPk({ periodo });
    \\  const { rows } = await pool.query(q.text, q.values);
    \\  if (rows.length !== 1 || rows[0].periodo !== periodo) {
    \\    throw new Error('round-trip mismatch: ' + JSON.stringify(rows));
    \\  }
    \\  console.log('ROUNDTRIP_OK');
    \\} finally {
    \\  const d = deletePeriodos({ periodo });
    \\  await pool.query(d.text, d.values);
    \\  await pool.end();
    \\}
;

// Same pattern for a `fecha` column (domain type backed by a nested struct,
// TS `{ año, mes, día }`): insert a `clases` row (after the periodos /
// materias / cursos rows its fk chain needs) -> selectByPk -> the `fecha` read
// back must be the same `{ año, mes, día }` that went in. Prints FECHA_OK.
const fecha_roundtrip_script =
    \\import {
    \\  insertPeriodos, deletePeriodos, insertMaterias, deleteMaterias,
    \\  insertCursos, deleteCursos, insertClases, selectClasesByPk, deleteClases,
    \\} from './src/dml.ts';
    \\import { deepStrictEqual } from 'node:assert';
    \\import pg from 'pg';
    \\const connectionString = process.env.DATABASE_URL ?? 'postgres://aida:aida@localhost:5432/aida';
    \\const pool = new pg.Pool({ connectionString });
    \\const run = (q) => pool.query(q.text, q.values);
    \\const periodo = 'it-' + Date.now();
    \\const materia = periodo;
    \\const curso = { periodo, materia };
    \\const clase = { ...curso, orden: 1 };
    \\const fecha = { año: 2026, mes: 3, día: 14 };
    \\try {
    \\  await run(insertPeriodos({ periodo }));
    \\  await run(insertMaterias({ materia, denominacion: materia }));
    \\  await run(insertCursos({ ...curso, docente: null }));
    \\  await run(insertClases({ ...clase, fecha, tema: 't' }));
    \\  const { rows } = await run(selectClasesByPk(clase));
    \\  console.log('stored fecha: ' + JSON.stringify(rows[0]?.fecha));
    \\  deepStrictEqual(rows[0]?.fecha, fecha);
    \\  console.log('FECHA_OK');
    \\} finally {
    \\  await run(deleteClases(clase));
    \\  await run(deleteCursos(curso));
    \\  await run(deleteMaterias({ materia }));
    \\  await run(deletePeriodos({ periodo }));
    \\  await pool.end();
    \\}
;

// `fecha` as part of a pk (`mesas`: periodo, materia, fecha): the lookup by pk
// must find the row even when the pk object has its keys in another order
// (`{ día, mes, año }`), and delete by that same pk must remove it. Prints
// MESAS_PK_OK.
const fecha_pk_script =
    \\import {
    \\  insertPeriodos, deletePeriodos, insertMaterias, deleteMaterias,
    \\  insertCursos, deleteCursos, insertMesas, selectMesasByPk, deleteMesas,
    \\} from './src/dml.ts';
    \\import { deepStrictEqual, equal } from 'node:assert';
    \\import pg from 'pg';
    \\const connectionString = process.env.DATABASE_URL ?? 'postgres://aida:aida@localhost:5432/aida';
    \\const pool = new pg.Pool({ connectionString });
    \\const run = (q) => pool.query(q.text, q.values);
    \\const periodo = 'it-pk-' + Date.now();
    \\const materia = periodo;
    \\const curso = { periodo, materia };
    \\const fecha = { año: 2026, mes: 7, día: 3 };
    \\const reordered = { día: 3, mes: 7, año: 2026 };
    \\try {
    \\  await run(insertPeriodos({ periodo }));
    \\  await run(insertMaterias({ materia, denominacion: materia }));
    \\  await run(insertCursos({ ...curso, docente: null }));
    \\  await run(insertMesas({ ...curso, fecha, presidente: null, vocal: null }));
    \\  const found = await run(selectMesasByPk({ ...curso, fecha: reordered }));
    \\  equal(found.rows.length, 1, 'selectByPk with reordered keys must find the row');
    \\  deepStrictEqual(found.rows[0].fecha, fecha);
    \\  await run(deleteMesas({ ...curso, fecha: reordered }));
    \\  const gone = await run(selectMesasByPk({ ...curso, fecha }));
    \\  equal(gone.rows.length, 0, 'delete with reordered keys must remove the row');
    \\  console.log('MESAS_PK_OK');
    \\} finally {
    \\  await run(deleteMesas({ ...curso, fecha }));
    \\  await run(deleteCursos(curso));
    \\  await run(deleteMaterias({ materia }));
    \\  await run(deletePeriodos({ periodo }));
    \\  await pool.end();
    \\}
;

// A nullable `fecha` (`clases.fecha`): inserting `null` reads back `null`
// (not a composite of NULLs), and updating it to a value and back to `null`
// round-trips too (the CASE WHEN ... IS NULL path of insert and update).
// Prints FECHA_NULL_OK.
const fecha_null_script =
    \\import {
    \\  insertPeriodos, deletePeriodos, insertMaterias, deleteMaterias,
    \\  insertCursos, deleteCursos, insertClases, selectClasesByPk, updateClases, deleteClases,
    \\} from './src/dml.ts';
    \\import { deepStrictEqual, strictEqual } from 'node:assert';
    \\import pg from 'pg';
    \\const connectionString = process.env.DATABASE_URL ?? 'postgres://aida:aida@localhost:5432/aida';
    \\const pool = new pg.Pool({ connectionString });
    \\const run = (q) => pool.query(q.text, q.values);
    \\const periodo = 'it-null-' + Date.now();
    \\const materia = periodo;
    \\const curso = { periodo, materia };
    \\const clase = { ...curso, orden: 1 };
    \\const fecha = { año: 2026, mes: 3, día: 14 };
    \\const read = async () => (await run(selectClasesByPk(clase))).rows[0].fecha;
    \\try {
    \\  await run(insertPeriodos({ periodo }));
    \\  await run(insertMaterias({ materia, denominacion: materia }));
    \\  await run(insertCursos({ ...curso, docente: null }));
    \\  await run(insertClases({ ...clase, fecha: null, tema: 't' }));
    \\  strictEqual(await read(), null, 'insert with fecha null');
    \\  await run(updateClases(clase, { fecha, tema: 't' }));
    \\  deepStrictEqual(await read(), fecha, 'update to a fecha');
    \\  await run(updateClases(clase, { fecha: null, tema: 't' }));
    \\  strictEqual(await read(), null, 'update back to null');
    \\  console.log('FECHA_NULL_OK');
    \\} finally {
    \\  await run(deleteClases(clase));
    \\  await run(deleteCursos(curso));
    \\  await run(deleteMaterias({ materia }));
    \\  await run(deletePeriodos({ periodo }));
    \\  await pool.end();
    \\}
;

// An `integer` column is i64 -> BIGINT / TS bigint: a value beyond
// Number.MAX_SAFE_INTEGER must come back as that exact bigint (pg's default
// returns BIGINT as a string). Uses `clases.orden` (part of its pk). Prints
// BIGINT_OK.
const bigint_script =
    \\import {
    \\  insertPeriodos, deletePeriodos, insertMaterias, deleteMaterias,
    \\  insertCursos, deleteCursos, insertClases, selectClasesByPk, deleteClases, pgTypes,
    \\} from './src/dml.ts';
    \\import { strictEqual } from 'node:assert';
    \\import pg from 'pg';
    \\const connectionString = process.env.DATABASE_URL ?? 'postgres://aida:aida@localhost:5432/aida';
    \\const pool = new pg.Pool({ connectionString, types: pgTypes(pg.types) });
    \\const run = (q) => pool.query(q.text, q.values);
    \\const periodo = 'it-bigint-' + Date.now();
    \\const materia = periodo;
    \\const curso = { periodo, materia };
    \\const orden = 9007199254740993n; // 2^53 + 1, not representable as a number
    \\const clase = { ...curso, orden };
    \\try {
    \\  await run(insertPeriodos({ periodo }));
    \\  await run(insertMaterias({ materia, denominacion: materia }));
    \\  await run(insertCursos({ ...curso, docente: null }));
    \\  await run(insertClases({ ...clase, fecha: null, tema: 't' }));
    \\  const { rows } = await run(selectClasesByPk(clase));
    \\  console.log('read orden: ' + typeof rows[0].orden + ' ' + String(rows[0].orden));
    \\  strictEqual(rows[0].orden, orden);
    \\  console.log('BIGINT_OK');
    \\} finally {
    \\  await run(deleteClases(clase));
    \\  await run(deleteCursos(curso));
    \\  await run(deleteMaterias({ materia }));
    \\  await run(deletePeriodos({ periodo }));
    \\  await pool.end();
    \\}
;

/// Runs `script` with node from `backend/` and expects exit 0 and `marker` on
/// stdout; on failure dumps node's stdout/stderr.
fn expectNodeScriptOk(script: []const u8, marker: []const u8) !void {
    const result = std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "node", "--input-type=module", "-e", script },
        .cwd = .{ .path = "backend" },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| {
        std.debug.print("could not run node: {s}\n", .{@errorName(err)});
        return err;
    };
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print(
            "node exited {any}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
            .{ result.term, result.stdout, result.stderr },
        );
        return error.RoundTripFailed;
    }

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, marker) != null);
}

test "generated DML builders round-trip against the docker-compose Postgres" {
    try expectNodeScriptOk(roundtrip_script, "ROUNDTRIP_OK");
}

test "a fecha column round-trips as { año, mes, día }" {
    try expectNodeScriptOk(fecha_roundtrip_script, "FECHA_OK");
}

test "a fecha in a pk finds and deletes the row whatever the key order of the object" {
    try expectNodeScriptOk(fecha_pk_script, "MESAS_PK_OK");
}

test "a nullable fecha round-trips null through insert and update" {
    try expectNodeScriptOk(fecha_null_script, "FECHA_NULL_OK");
}

test "an integer (i64) column round-trips an exact bigint beyond 2^53" {
    try expectNodeScriptOk(bigint_script, "BIGINT_OK");
}
