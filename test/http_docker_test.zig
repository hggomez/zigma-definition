//! The generated HTTP server (backend/src/server.ts) running as the
//! long-running process of the `backend` service of docker-compose.yml, and
//! called over HTTP from the host: GET /api/<entity> lists the rows of the real
//! database as a bare JSON array, for every entity of aida, and an unknown path
//! is a JSON 404.
//!
//! Each field keeps its SSOT type in the JSON: a bigint (aida's `integer`,
//! i64, BIGINT in Postgres) is an exact JSON number, never rounded through a JS
//! number nor sent as a string; a `fecha` (a struct, a composite type in
//! Postgres) is `{ "año", "mes", "día" }`, or null.
//!
//! The test seeds rows straight into Postgres (psql inside the postgres
//! container): a periodo, and a clase (with its materia and curso) whose
//! `orden` is 2^53 + 1 and another one without `fecha`. It requests the API
//! from the host with Node's fetch, and removes the rows afterwards.
//!
//! Run with `zig build http-docker`, which regenerates dml.ts + server.ts
//! into backend/, applies the aida schema, builds the image and brings the
//! backend up (waiting for its healthcheck). Not part of `zig build test`
//! (needs Docker + Node).

const std = @import("std");

fn psql(sql: []const u8) !void {
    const result = try std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "docker", "exec", "zigma_aida_postgres", "psql", "-U", "aida", "-d", "aida", "-v", "ON_ERROR_STOP=1", "-c", sql },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("psql failed: {s}\n", .{result.stderr});
        return error.PsqlFailed;
    }
}

// Every row the test writes, keyed by the same value; removed child-first.
const cleanup =
    \\DELETE FROM clases WHERE periodo = 'http-docker-test';
    \\DELETE FROM cursos WHERE periodo = 'http-docker-test';
    \\DELETE FROM materias WHERE materia = 'http-docker-test';
    \\DELETE FROM periodos WHERE periodo = 'http-docker-test';
;

const seed =
    \\INSERT INTO periodos (periodo) VALUES ('http-docker-test');
    \\INSERT INTO materias (materia, denominacion) VALUES ('http-docker-test', 'http-docker-test');
    \\INSERT INTO cursos (periodo, materia) VALUES ('http-docker-test', 'http-docker-test');
    \\INSERT INTO clases (periodo, materia, orden, fecha, tema) VALUES
    \\  ('http-docker-test', 'http-docker-test', 9007199254740993, ROW(2026, 3, 14), NULL),
    \\  ('http-docker-test', 'http-docker-test', 1, NULL, 'sin fecha');
;

// An ES module run on the host with `node --input-type=module -e`: requests
// the API published by the backend container. Prints HTTP_OK when every
// assert holds.
const script =
    \\import assert from 'node:assert/strict';
    \\const base = 'http://localhost:3000';
    \\
    \\// every entity of aida has its list: 200, JSON, a bare array
    \\const entities = ['docentes', 'materias', 'periodos', 'cursos', 'clases', 'alumnos',
    \\  'preguntas', 'opciones', 'inscripciones', 'presencias', 'mesas'];
    \\for (const entity of entities) {
    \\  const res = await fetch(base + '/api/' + entity);
    \\  assert.equal(res.status, 200, entity);
    \\  assert.match(res.headers.get('content-type') ?? '', /^application\/json/, entity);
    \\  assert.ok(Array.isArray(await res.json()), entity + ': the list is a bare array');
    \\}
    \\
    \\// the rows, with exactly the entity's fields
    \\let res = await fetch(base + '/api/periodos');
    \\const periodos = await res.json();
    \\assert.deepEqual(periodos.filter((r) => r.periodo === 'http-docker-test'), [{ periodo: 'http-docker-test' }]);
    \\for (const row of periodos) assert.deepEqual(Object.keys(row), ['periodo']);
    \\
    \\// a bigint is an exact JSON number (2^53 + 1 is not a JS number: it only
    \\// survives if it is not rounded through one), a fecha is { año, mes, día }
    \\res = await fetch(base + '/api/clases');
    \\const text = await res.text();
    \\assert.match(text, /"orden":9007199254740993[,}]/, 'orden must be the exact JSON number');
    \\const clases = JSON.parse(text, (key, value, context) => key === 'orden' ? BigInt(context.source) : value)
    \\  .filter((r) => r.periodo === 'http-docker-test')
    \\  .sort((a, b) => (a.orden < b.orden ? -1 : 1));
    \\assert.deepEqual(clases, [
    \\  { periodo: 'http-docker-test', materia: 'http-docker-test', orden: 1n, fecha: null, tema: 'sin fecha' },
    \\  { periodo: 'http-docker-test', materia: 'http-docker-test', orden: 9007199254740993n, fecha: { año: 2026, mes: 3, día: 14 }, tema: null },
    \\]);
    \\for (const row of clases) assert.deepEqual(Object.keys(row), ['periodo', 'materia', 'orden', 'fecha', 'tema']);
    \\
    \\// an unknown path: 404 with a JSON error
    \\res = await fetch(base + '/api/inexistentes');
    \\assert.equal(res.status, 404);
    \\assert.match(res.headers.get('content-type') ?? '', /^application\/json/);
    \\assert.deepEqual(await res.json(), { error: 'not found' });
    \\
    \\console.log('HTTP_OK');
;

test "the backend container lists every entity from the real database, each field with its SSOT type" {
    try psql(cleanup);
    try psql(seed);
    defer psql(cleanup) catch {};

    const result = std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "node", "--input-type=module", "-e", script },
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
        return error.HttpDockerFailed;
    }

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "HTTP_OK") != null);
}
