//! The generated DML (backend/src/dml.ts) against the real database, without
//! the HTTP layer: the same data flow as test-api below server.ts. The script
//! runs inside the backend container (`docker compose run --rm backend`), so
//! Node, pg and the network to the `postgres` service are the server's.
//!
//! The values handed to the builders are the ones server.ts hands them after
//! reading a request: text as a string, a bigint (aida's `integer`, i64) as a
//! JS bigint, a `fecha` as the composite's literal "(año,mes,día)", an absent
//! nullable field as null. The rows are checked as pg returns them to
//! server.ts, before it encodes them as JSON: a bigint as its decimal text
//! (2^53 + 1 exact), a `fecha` as "(año,mes,día)".
//!
//! For every entity of aida, parents first (fks): insert, select by pk, the
//! row in select all, update (the entities with fields outside the pk), and
//! at the end delete, child first, then select by pk is empty. Every row has
//! the marker "backend-db-test"; leftovers of a failed run are removed with
//! plain SQL before and after, so the cleanup does not depend on the code
//! under test.
//!
//! Run with `zig build test-backend-db`, which regenerates dml.ts (and
//! server.ts) into backend/, applies the aida schema and builds the backend
//! image. Not part of `zig build test` (needs Docker).

const std = @import("std");

// An ES module run inside the container with `node --input-type=module -e`,
// from the image's working directory (where ./src/dml.ts and pg are).
// Prints BACKEND_DB_OK when every assert holds.
const script =
    \\import assert from 'node:assert/strict';
    \\import pg from 'pg';
    \\import * as dml from './src/dml.ts';
    \\
    \\const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
    \\const run = async (q) => (await pool.query(q.text, q.values)).rows;
    \\
    \\// every row of the test, child first: plain SQL, not the code under test
    \\const cleanup = `
    \\  DELETE FROM presencias WHERE periodo = 'backend-db-test';
    \\  DELETE FROM inscripciones WHERE periodo = 'backend-db-test';
    \\  DELETE FROM opciones WHERE periodo = 'backend-db-test';
    \\  DELETE FROM preguntas WHERE periodo = 'backend-db-test';
    \\  DELETE FROM clases WHERE periodo = 'backend-db-test';
    \\  DELETE FROM mesas WHERE periodo = 'backend-db-test';
    \\  DELETE FROM cursos WHERE periodo = 'backend-db-test';
    \\  DELETE FROM alumnos WHERE alumno = 'backend-db-test';
    \\  DELETE FROM materias WHERE materia = 'backend-db-test';
    \\  DELETE FROM periodos WHERE periodo = 'backend-db-test';
    \\  DELETE FROM docentes WHERE docente IN ('backend-db-test-2', 'backend-db-test');`;
    \\
    \\const t = 'backend-db-test';
    \\const big = 9007199254740993n; // 2^53 + 1: not a JS number
    \\const curso = { periodo: t, materia: t };
    \\const clase = { ...curso, orden: big };
    \\const pregunta = { ...clase, pregunta: 1n };
    \\
    \\// [name, pk, row as server.ts passes it, fields for update (or null),
    \\//  the row as pg returns it, the row after the update as pg returns it]
    \\const entities = [
    \\  ['Docentes', { docente: t },
    \\    { docente: t, apellido: 'apellido', nombres: 'nombres', cargo: null, email: null, email_alternativo: null, jefe: null },
    \\    { apellido: 'apellido', nombres: 'nombres', cargo: 'cargo', email: 'e@x', email_alternativo: null, jefe: null },
    \\    { docente: t, apellido: 'apellido', nombres: 'nombres', cargo: null, email: null, email_alternativo: null, jefe: null },
    \\    { docente: t, apellido: 'apellido', nombres: 'nombres', cargo: 'cargo', email: 'e@x', email_alternativo: null, jefe: null }],
    \\  // a docente whose jefe is another one: the reflexive fk
    \\  ['Docentes', { docente: t + '-2' },
    \\    { docente: t + '-2', apellido: 'a', nombres: 'n', cargo: null, email: null, email_alternativo: null, jefe: t },
    \\    null,
    \\    { docente: t + '-2', apellido: 'a', nombres: 'n', cargo: null, email: null, email_alternativo: null, jefe: t }, null],
    \\  ['Materias', { materia: t }, { materia: t, denominacion: t }, { denominacion: t + ' bis' },
    \\    { materia: t, denominacion: t }, { materia: t, denominacion: t + ' bis' }],
    \\  ['Periodos', { periodo: t }, { periodo: t }, null, { periodo: t }, null],
    \\  ['Cursos', curso, { ...curso, docente: null }, { docente: t },
    \\    { ...curso, docente: null }, { ...curso, docente: t }],
    \\  ['Clases', clase, { ...clase, fecha: '(2026,3,14)', tema: null }, { fecha: null, tema: 'tema' },
    \\    { ...curso, orden: '9007199254740993', fecha: '(2026,3,14)', tema: null },
    \\    { ...curso, orden: '9007199254740993', fecha: null, tema: 'tema' }],
    \\  ['Alumnos', { alumno: t }, { alumno: t, apellido: 'apellido', nombres: 'nombres', email: null },
    \\    { apellido: 'apellido', nombres: 'nombres', email: 'e@x' },
    \\    { alumno: t, apellido: 'apellido', nombres: 'nombres', email: null },
    \\    { alumno: t, apellido: 'apellido', nombres: 'nombres', email: 'e@x' }],
    \\  ['Preguntas', pregunta, { ...pregunta, formulacion: 'f', aclaraciones: null, tipo_respuesta: 'r' },
    \\    { formulacion: 'f', aclaraciones: 'a', tipo_respuesta: 'r' },
    \\    { ...curso, orden: '9007199254740993', pregunta: '1', formulacion: 'f', aclaraciones: null, tipo_respuesta: 'r' },
    \\    { ...curso, orden: '9007199254740993', pregunta: '1', formulacion: 'f', aclaraciones: 'a', tipo_respuesta: 'r' }],
    \\  ['Opciones', { ...pregunta, opcion: 'o' }, { ...pregunta, opcion: 'o', detalle: null }, { detalle: 'd' },
    \\    { ...curso, orden: '9007199254740993', pregunta: '1', opcion: 'o', detalle: null },
    \\    { ...curso, orden: '9007199254740993', pregunta: '1', opcion: 'o', detalle: 'd' }],
    \\  ['Inscripciones', { ...curso, alumno: t }, { ...curso, alumno: t }, null, { ...curso, alumno: t }, null],
    \\  ['Presencias', { ...curso, alumno: t, orden: big }, { ...curso, alumno: t, orden: big }, null,
    \\    { ...curso, alumno: t, orden: '9007199254740993' }, null],
    \\  ['Mesas', { ...curso, fecha: '(2026,3,14)' }, { ...curso, fecha: '(2026,3,14)', presidente: null, vocal: null },
    \\    { presidente: t, vocal: null },
    \\    { ...curso, fecha: '(2026,3,14)', presidente: null, vocal: null },
    \\    { ...curso, fecha: '(2026,3,14)', presidente: t, vocal: null }],
    \\];
    \\
    \\try {
    \\  await pool.query(cleanup);
    \\
    \\  for (const [name, pk, row, set, stored, updated] of entities) {
    \\    await run(dml['insert' + name](row));
    \\    assert.deepEqual(await run(dml['select' + name + 'ByPk'](pk)), [stored], name + ': select by pk after insert');
    \\    const all = await run(dml['selectAll' + name]());
    \\    assert.ok(all.some((r) => { try { assert.deepEqual(r, stored); return true; } catch { return false; } }), name + ': in select all');
    \\    if (set !== null) {
    \\      await run(dml['update' + name](pk, set));
    \\      assert.deepEqual(await run(dml['select' + name + 'ByPk'](pk)), [updated], name + ': select by pk after update');
    \\    }
    \\  }
    \\
    \\  for (const [name, pk] of [...entities].reverse()) {
    \\    await run(dml['delete' + name](pk));
    \\    assert.deepEqual(await run(dml['select' + name + 'ByPk'](pk)), [], name + ': select by pk after delete');
    \\  }
    \\  console.log('BACKEND_DB_OK');
    \\} finally {
    \\  await pool.query(cleanup);
    \\  await pool.end();
    \\}
;

test "the generated DML, inside the backend container, inserts, reads, updates and deletes a row of every entity, with the values of test-api" {
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "docker", "compose", "run", "--rm", "-T", "backend", "node", "--input-type=module", "-e", script },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print(
            "the backend container exited {any}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
            .{ result.term, result.stdout, result.stderr },
        );
        return error.BackendDbFailed;
    }

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "BACKEND_DB_OK") != null);
}
