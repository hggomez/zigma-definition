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
