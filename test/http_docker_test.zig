//! The generated HTTP server (backend/src/server.ts) running as the
//! long-running process of the `backend` service of docker-compose.yml, and
//! called over HTTP from the host: GET /api/<entity> lists the rows of the real
//! database as a bare JSON array, for every entity of aida; with the full pk in
//! the query string it returns that row (or a JSON 404), for the entities whose
//! pk is text only, and DELETE with the full pk removes it (204, or a JSON 404
//! when it was not there); a query string that is not exactly the pk is a JSON
//! 400; POST with the row as a JSON body creates it (201), for the entities
//! whose fields are all text, and a body that is not a row of the entity is a
//! JSON 400; PUT with the pk in the query string and the other fields as a
//! JSON body updates the row (204, or a JSON 404 when it was not there); a
//! body takes a bigint as an exact JSON number and a fecha as an object, each
//! checked against its type (a JSON 400 naming the field); an unknown path is
//! a JSON 404.
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
//! Run with `zig build test-api`, which regenerates dml.ts + server.ts
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
    \\DELETE FROM mesas WHERE periodo = 'http-docker-test';
    \\DELETE FROM cursos WHERE periodo = 'http-docker-test';
    \\DELETE FROM materias WHERE materia = 'http-docker-test';
    \\DELETE FROM docentes WHERE docente = 'http-docker-test';
    \\DELETE FROM periodos WHERE periodo IN ('http-docker-test', 'http-docker-test-delete', 'http-docker-test-create');
;

const seed =
    \\INSERT INTO periodos (periodo) VALUES ('http-docker-test'), ('http-docker-test-delete');
    \\INSERT INTO materias (materia, denominacion) VALUES ('http-docker-test', 'http-docker-test');
    \\INSERT INTO cursos (periodo, materia) VALUES ('http-docker-test', 'http-docker-test');
    \\INSERT INTO clases (periodo, materia, orden, fecha, tema) VALUES
    \\  ('http-docker-test', 'http-docker-test', 9007199254740993, ROW(2026, 3, 14), NULL),
    \\  ('http-docker-test', 'http-docker-test', 1, NULL, 'sin fecha');
    \\INSERT INTO mesas (periodo, materia, fecha) VALUES ('http-docker-test', 'http-docker-test', ROW(2026, 3, 14));
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
    \\// one row: the full pk in the query string -> the object, or a JSON 404
    \\res = await fetch(base + '/api/periodos?periodo=http-docker-test');
    \\assert.equal(res.status, 200);
    \\assert.deepEqual(await res.json(), { periodo: 'http-docker-test' });
    \\res = await fetch(base + '/api/periodos?periodo=no-such-periodo');
    \\assert.equal(res.status, 404);
    \\assert.deepEqual(await res.json(), { error: 'not found' });
    \\// a composite text pk, its fields in any order
    \\res = await fetch(base + '/api/cursos?materia=http-docker-test&periodo=http-docker-test');
    \\assert.equal(res.status, 200);
    \\assert.deepEqual(await res.json(), { periodo: 'http-docker-test', materia: 'http-docker-test', docente: null });
    \\
    \\// a query string that is not exactly the pk: 400 with a JSON error
    \\for (const [query, error] of [
    \\  ['/api/periodos?periodo=http-docker-test&foo=1', "unknown parameter 'foo'"],
    \\  ['/api/periodos?periodo=a&periodo=b', "repeated parameter 'periodo'"],
    \\  ['/api/cursos?periodo=http-docker-test', "missing pk field 'materia'"],
    \\]) {
    \\  res = await fetch(base + query);
    \\  assert.equal(res.status, 400, query);
    \\  assert.match(res.headers.get('content-type') ?? '', /^application\/json/, query);
    \\  assert.deepEqual(await res.json(), { error }, query);
    \\}
    \\
    \\// delete: 204 without a body, then the row is gone; deleting it again is a
    \\// JSON 404; without the full pk it is a JSON 400 (never "delete everything")
    \\res = await fetch(base + '/api/periodos?periodo=http-docker-test-delete', { method: 'DELETE' });
    \\assert.equal(res.status, 204);
    \\assert.equal(await res.text(), '');
    \\res = await fetch(base + '/api/periodos?periodo=http-docker-test-delete');
    \\assert.equal(res.status, 404);
    \\res = await fetch(base + '/api/periodos?periodo=http-docker-test-delete', { method: 'DELETE' });
    \\assert.equal(res.status, 404);
    \\assert.deepEqual(await res.json(), { error: 'not found' });
    \\res = await fetch(base + '/api/periodos', { method: 'DELETE' });
    \\assert.equal(res.status, 400);
    \\assert.deepEqual(await res.json(), { error: "missing pk field 'periodo'" });
    \\// a row other rows reference (the periodo of a curso): Postgres rejects
    \\// it; for now the generic 500 (pk/uk/fk violations, all together: later)
    \\res = await fetch(base + '/api/periodos?periodo=http-docker-test', { method: 'DELETE' });
    \\assert.equal(res.status, 500);
    \\assert.deepEqual(await res.json(), { error: 'internal error' });
    \\res = await fetch(base + '/api/periodos?periodo=http-docker-test');
    \\assert.equal(res.status, 200, 'the referenced row is still there');
    \\
    \\// a bigint in the pk: decimal digits, exact (2^53 + 1); not an integer, or
    \\// outside the i64 interval: a JSON 400
    \\const clasePk = '/api/clases?periodo=http-docker-test&materia=http-docker-test&orden=';
    \\res = await fetch(base + clasePk + '9007199254740993');
    \\assert.equal(res.status, 200);
    \\const clase = await res.text();
    \\assert.match(clase, /"orden":9007199254740993[,}]/);
    \\assert.deepEqual(JSON.parse(clase, (key, value, context) => key === 'orden' ? BigInt(context.source) : value),
    \\  { periodo: 'http-docker-test', materia: 'http-docker-test', orden: 9007199254740993n, fecha: { año: 2026, mes: 3, día: 14 }, tema: null });
    \\for (const orden of ['abc', '1.5', '9223372036854775808']) {
    \\  res = await fetch(base + clasePk + orden);
    \\  assert.equal(res.status, 400, orden);
    \\  assert.deepEqual(await res.json(), { error: "field 'orden' must be an integer in -9223372036854775808..9223372036854775807" }, orden);
    \\}
    \\
    \\// a struct in the pk: one parameter per field, each inside its interval
    \\const mesaPk = '/api/mesas?periodo=http-docker-test&materia=http-docker-test';
    \\res = await fetch(base + mesaPk + '&fecha.año=2026&fecha.mes=3&fecha.día=14');
    \\assert.equal(res.status, 200);
    \\assert.deepEqual(await res.json(), { periodo: 'http-docker-test', materia: 'http-docker-test', fecha: { año: 2026, mes: 3, día: 14 }, presidente: null, vocal: null });
    \\res = await fetch(base + mesaPk + '&fecha.año=2026&fecha.mes=300&fecha.día=14');
    \\assert.equal(res.status, 400);
    \\assert.deepEqual(await res.json(), { error: "field 'fecha.mes' must be an integer in 0..255" });
    \\res = await fetch(base + mesaPk + '&fecha.año=2026&fecha.mes=3');
    \\assert.equal(res.status, 400);
    \\assert.deepEqual(await res.json(), { error: "missing pk field 'fecha.día'" });
    \\
    \\// delete by a bigint pk and by a struct pk
    \\res = await fetch(base + clasePk + '1', { method: 'DELETE' });
    \\assert.equal(res.status, 204);
    \\res = await fetch(base + clasePk + '1');
    \\assert.equal(res.status, 404);
    \\res = await fetch(base + mesaPk + '&fecha.año=2026&fecha.mes=3&fecha.día=14', { method: 'DELETE' });
    \\assert.equal(res.status, 204);
    \\res = await fetch(base + mesaPk + '&fecha.año=2026&fecha.mes=3&fecha.día=14');
    \\assert.equal(res.status, 404);
    \\
    \\// create: 201 without a body, then the row is there; a nullable field the
    \\// body leaves out is null
    \\res = await fetch(base + '/api/periodos', { method: 'POST', body: JSON.stringify({ periodo: 'http-docker-test-create' }) });
    \\assert.equal(res.status, 201);
    \\assert.equal(await res.text(), '');
    \\res = await fetch(base + '/api/periodos?periodo=http-docker-test-create');
    \\assert.deepEqual(await res.json(), { periodo: 'http-docker-test-create' });
    \\res = await fetch(base + '/api/docentes', { method: 'POST', body: JSON.stringify({ docente: 'http-docker-test', apellido: 'Apellido', nombres: 'Nombres', email: 'a@b.c' }) });
    \\assert.equal(res.status, 201);
    \\res = await fetch(base + '/api/docentes?docente=http-docker-test');
    \\assert.deepEqual(await res.json(), { docente: 'http-docker-test', apellido: 'Apellido', nombres: 'Nombres', cargo: null, email: 'a@b.c', email_alternativo: null, jefe: null });
    \\
    \\// a body that is not a row of the entity: 400 with a JSON error
    \\for (const [body, error] of [
    \\  ['not json', 'body is not valid JSON'],
    \\  ['[1]', 'body must be a JSON object'],
    \\  [JSON.stringify({ periodo: 'x', foo: 1 }), "unknown field 'foo'"],
    \\  [JSON.stringify({}), "missing field 'periodo'"],
    \\  [JSON.stringify({ periodo: null }), "field 'periodo' must not be null"],
    \\  [JSON.stringify({ periodo: 1 }), "field 'periodo' must be a string"],
    \\]) {
    \\  res = await fetch(base + '/api/periodos', { method: 'POST', body });
    \\  assert.equal(res.status, 400, body);
    \\  assert.deepEqual(await res.json(), { error }, body);
    \\}
    \\// a duplicate pk: Postgres rejects it; for now the generic 500
    \\res = await fetch(base + '/api/periodos', { method: 'POST', body: JSON.stringify({ periodo: 'http-docker-test' }) });
    \\assert.equal(res.status, 500);
    \\assert.deepEqual(await res.json(), { error: 'internal error' });
    \\
    \\// update: the pk in the query string, the other fields in the body; 204
    \\// without a body, then the row has the new values
    \\res = await fetch(base + '/api/materias?materia=http-docker-test', { method: 'PUT', body: JSON.stringify({ denominacion: 'http-docker-test-updated' }) });
    \\assert.equal(res.status, 204);
    \\assert.equal(await res.text(), '');
    \\res = await fetch(base + '/api/materias?materia=http-docker-test');
    \\assert.deepEqual(await res.json(), { materia: 'http-docker-test', denominacion: 'http-docker-test-updated' });
    \\// a composite pk; a nullable field set, then left out of the body: null
    \\res = await fetch(base + '/api/cursos?periodo=http-docker-test&materia=http-docker-test', { method: 'PUT', body: JSON.stringify({ docente: 'http-docker-test' }) });
    \\assert.equal(res.status, 204);
    \\res = await fetch(base + '/api/cursos?periodo=http-docker-test&materia=http-docker-test');
    \\assert.deepEqual(await res.json(), { periodo: 'http-docker-test', materia: 'http-docker-test', docente: 'http-docker-test' });
    \\res = await fetch(base + '/api/cursos?periodo=http-docker-test&materia=http-docker-test', { method: 'PUT', body: '{}' });
    \\assert.equal(res.status, 204);
    \\res = await fetch(base + '/api/cursos?periodo=http-docker-test&materia=http-docker-test');
    \\assert.deepEqual(await res.json(), { periodo: 'http-docker-test', materia: 'http-docker-test', docente: null });
    \\// no row with that pk: a JSON 404 (nothing is created)
    \\res = await fetch(base + '/api/materias?materia=no-such-materia', { method: 'PUT', body: JSON.stringify({ denominacion: 'x' }) });
    \\assert.equal(res.status, 404);
    \\assert.deepEqual(await res.json(), { error: 'not found' });
    \\res = await fetch(base + '/api/materias?materia=no-such-materia');
    \\assert.equal(res.status, 404);
    \\// the pk only goes in the query string; without it, a JSON 400
    \\res = await fetch(base + '/api/materias?materia=http-docker-test', { method: 'PUT', body: JSON.stringify({ materia: 'other', denominacion: 'x' }) });
    \\assert.equal(res.status, 400);
    \\assert.deepEqual(await res.json(), { error: "unknown field 'materia'" });
    \\res = await fetch(base + '/api/materias', { method: 'PUT', body: JSON.stringify({ denominacion: 'x' }) });
    \\assert.equal(res.status, 400);
    \\assert.deepEqual(await res.json(), { error: "missing pk field 'materia'" });
    \\// an entity that is all pk has nothing to update: no route
    \\res = await fetch(base + '/api/periodos?periodo=http-docker-test', { method: 'PUT', body: '{}' });
    \\assert.equal(res.status, 404);
    \\
    \\// a body with a bigint and a struct, in the format of the responses: the
    \\// bigint an exact JSON number (written as text: JSON.stringify throws on a
    \\// bigint), the fecha an object { año, mes, día }
    \\const claseBody = (orden, fecha) => '{"periodo":"http-docker-test","materia":"http-docker-test","orden":' + orden + (fecha === undefined ? '' : ',"fecha":' + fecha) + '}';
    \\const readExact = async (res) => JSON.parse(await res.text(), (key, value, context) => key === 'orden' ? BigInt(context.source) : value);
    \\res = await fetch(base + '/api/clases', { method: 'POST', body: claseBody('9007199254740995', '{"año":2026,"mes":4,"día":1}') });
    \\assert.equal(res.status, 201);
    \\res = await fetch(base + clasePk + '9007199254740995');
    \\assert.deepEqual(await readExact(res),
    \\  { periodo: 'http-docker-test', materia: 'http-docker-test', orden: 9007199254740995n, fecha: { año: 2026, mes: 4, día: 1 }, tema: null });
    \\// update a struct and a text field; a nullable struct set to null
    \\res = await fetch(base + clasePk + '9007199254740995', { method: 'PUT', body: JSON.stringify({ fecha: null, tema: 'con tema' }) });
    \\assert.equal(res.status, 204);
    \\res = await fetch(base + clasePk + '9007199254740995');
    \\assert.deepEqual(await readExact(res),
    \\  { periodo: 'http-docker-test', materia: 'http-docker-test', orden: 9007199254740995n, fecha: null, tema: 'con tema' });
    \\res = await fetch(base + clasePk + '9007199254740995', { method: 'PUT', body: JSON.stringify({ fecha: { año: 2026, mes: 5, día: 2 } }) });
    \\assert.equal(res.status, 204);
    \\res = await fetch(base + clasePk + '9007199254740995');
    \\assert.deepEqual(await readExact(res),
    \\  { periodo: 'http-docker-test', materia: 'http-docker-test', orden: 9007199254740995n, fecha: { año: 2026, mes: 5, día: 2 }, tema: null });
    \\// a struct in the pk of a create
    \\res = await fetch(base + '/api/mesas', { method: 'POST', body: JSON.stringify({ periodo: 'http-docker-test', materia: 'http-docker-test', fecha: { año: 2026, mes: 7, día: 1 }, presidente: 'http-docker-test' }) });
    \\assert.equal(res.status, 201);
    \\res = await fetch(base + mesaPk + '&fecha.año=2026&fecha.mes=7&fecha.día=1');
    \\assert.deepEqual(await res.json(), { periodo: 'http-docker-test', materia: 'http-docker-test', fecha: { año: 2026, mes: 7, día: 1 }, presidente: 'http-docker-test', vocal: null });
    \\
    \\// a bigint or a struct that does not fit its type: a JSON 400 naming the field
    \\const ordenError = "field 'orden' must be an integer in -9223372036854775808..9223372036854775807";
    \\for (const [body, error] of [
    \\  [claseBody('1.5'), ordenError],
    \\  [claseBody('"3"'), ordenError],
    \\  [claseBody('9223372036854775808'), ordenError],
    \\  [claseBody('8', '"2026-03-14"'), "field 'fecha' must be an object"],
    \\  [claseBody('8', '{"año":2026,"mes":300,"día":1}'), "field 'fecha.mes' must be an integer in 0..255"],
    \\  [claseBody('8', '{"año":2026,"mes":3}'), "missing field 'fecha.día'"],
    \\  [claseBody('8', '{"año":2026,"mes":null,"día":1}'), "field 'fecha.mes' must not be null"],
    \\  [claseBody('8', '{"año":2026,"mes":3,"día":1,"hora":9}'), "unknown field 'fecha.hora'"],
    \\]) {
    \\  res = await fetch(base + '/api/clases', { method: 'POST', body });
    \\  assert.equal(res.status, 400, body);
    \\  assert.deepEqual(await res.json(), { error }, body);
    \\}
    \\
    \\// an unknown path: 404 with a JSON error
    \\res = await fetch(base + '/api/inexistentes');
    \\assert.equal(res.status, 404);
    \\assert.match(res.headers.get('content-type') ?? '', /^application\/json/);
    \\assert.deepEqual(await res.json(), { error: 'not found' });
    \\
    \\console.log('HTTP_OK');
;

test "the backend container lists every entity, reads, deletes, creates and updates one row, each field with its SSOT type" {
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
