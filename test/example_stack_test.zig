//! The example stack: a second copy of the generated frontend, backend and
//! Postgres (compose project `zigma-example`, docker-compose.example.yml on
//! top of docker-compose.yml), separate from the one the tests use, filled
//! with the fake rows of examples/aida_seed.sql to browse the frontend by hand
//! at http://localhost:8081.
//!
//! The test checks what `zig build example` leaves running: the frontend
//! published on 8081 is the one of the `zigma-example` project (not the test
//! stack's), it serves the index, and through it every entity of aida lists
//! exactly the rows of the seed, by their fake pks (`docente-1`, …), none
//! more: a row left from before the run (one added by hand while browsing)
//! means the database was not reset. A few rows are checked whole: the
//! reflexive fk, a clase without fecha, a bigint above 2^53 read exactly.
//!
//! Run with `zig build example`, which regenerates the backend and the
//! frontend, brings the example stack up, resets its database (schema + seed)
//! and ends with this check; the stack keeps running until `zig build
//! example-down`. Not part of `zig build test` (needs Docker + Node).

const std = @import("std");

fn run(argv: []const []const u8) !std.process.RunResult {
    return std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    });
}

test "the frontend on 8081 is the one of the zigma-example project" {
    const result = try run(&.{ "docker", "ps", "--filter", "publish=8081", "--format", "{{.Label \"com.docker.compose.project\"}}" });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    try std.testing.expectEqualStrings("zigma-example", std.mem.trim(u8, result.stdout, " \r\n"));
}

// An ES module run on the host with `node --input-type=module -e`: requests
// the example frontend (and the API behind its /api proxy). Every JSON number
// is read as its exact text (2^53 + 1 is not a JS number). Prints EXAMPLE_OK
// when every assert holds.
const script =
    \\import assert from 'node:assert/strict';
    \\const base = 'http://localhost:8081';
    \\const list = async (entity) => {
    \\  const res = await fetch(base + '/api/' + entity);
    \\  assert.equal(res.status, 200, entity);
    \\  return JSON.parse(await res.text(), (key, value, context) => (typeof value === 'number' ? context.source : value));
    \\};
    \\
    \\const index = await fetch(base + '/');
    \\assert.equal(index.status, 200, 'the index');
    \\
    \\// every entity: exactly the pks of the seed, none more
    \\const fecha = (f) => `${f.año}-${f.mes}-${f.día}`;
    \\const pks = {
    \\  docentes: [(r) => r.docente, ['docente-1', 'docente-2', 'docente-3']],
    \\  materias: [(r) => r.materia, ['materia-1', 'materia-2', 'materia-3']],
    \\  periodos: [(r) => r.periodo, ['periodo-1', 'periodo-2', 'periodo-3']],
    \\  cursos: [(r) => `${r.periodo} ${r.materia}`, ['periodo-1 materia-1', 'periodo-1 materia-2', 'periodo-2 materia-1']],
    \\  clases: [(r) => `${r.periodo} ${r.materia} ${r.orden}`,
    \\    ['periodo-1 materia-1 1', 'periodo-1 materia-1 2', 'periodo-1 materia-2 9007199254740993']],
    \\  alumnos: [(r) => r.alumno, ['alumno-1', 'alumno-2', 'alumno-3']],
    \\  preguntas: [(r) => `${r.periodo} ${r.materia} ${r.orden} ${r.pregunta}`,
    \\    ['periodo-1 materia-1 1 1', 'periodo-1 materia-1 1 2', 'periodo-1 materia-1 2 1']],
    \\  opciones: [(r) => `${r.periodo} ${r.materia} ${r.orden} ${r.pregunta} ${r.opcion}`,
    \\    ['periodo-1 materia-1 1 1 opcion-1', 'periodo-1 materia-1 1 1 opcion-2', 'periodo-1 materia-1 1 2 opcion-1']],
    \\  inscripciones: [(r) => `${r.periodo} ${r.materia} ${r.alumno}`,
    \\    ['periodo-1 materia-1 alumno-1', 'periodo-1 materia-1 alumno-2', 'periodo-1 materia-2 alumno-1']],
    \\  presencias: [(r) => `${r.periodo} ${r.materia} ${r.alumno} ${r.orden}`,
    \\    ['periodo-1 materia-1 alumno-1 1', 'periodo-1 materia-1 alumno-1 2', 'periodo-1 materia-1 alumno-2 1']],
    \\  mesas: [(r) => `${r.periodo} ${r.materia} ${fecha(r.fecha)}`,
    \\    ['periodo-1 materia-1 2026-7-1', 'periodo-1 materia-2 2026-7-2', 'periodo-2 materia-1 2026-12-1']],
    \\};
    \\const rows = {};
    \\for (const [entity, [pk, expected]] of Object.entries(pks)) {
    \\  rows[entity] = await list(entity);
    \\  assert.deepEqual(rows[entity].map(pk).sort(), expected, entity + ': exactly the rows of the seed');
    \\}
    \\
    \\// a few rows whole: the fake values, the edge cases of the seed
    \\const find = (entity, pred) => rows[entity].find(pred);
    \\assert.deepEqual(find('docentes', (r) => r.docente === 'docente-2'),
    \\  { docente: 'docente-2', apellido: 'apellido-2', nombres: 'nombres-2', cargo: 'cargo-2', email: null, email_alternativo: null, jefe: 'docente-1' });
    \\assert.deepEqual(find('clases', (r) => r.orden === '2'),
    \\  { periodo: 'periodo-1', materia: 'materia-1', orden: '2', fecha: null, tema: 'tema-2' });
    \\assert.deepEqual(find('clases', (r) => r.orden === '9007199254740993'),
    \\  { periodo: 'periodo-1', materia: 'materia-2', orden: '9007199254740993', fecha: { año: '2026', mes: '4', día: '1' }, tema: null });
    \\assert.deepEqual(find('alumnos', (r) => r.alumno === 'alumno-1'),
    \\  { alumno: 'alumno-1', apellido: 'apellido-1', nombres: 'nombres-1', email: 'alumno-1@example.com' });
    \\console.log('EXAMPLE_OK');
;

test "the example frontend serves the index and lists rows of every entity" {
    const result = run(&.{ "node", "--input-type=module", "-e", script }) catch |err| {
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
        return error.ExampleStackFailed;
    }

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "EXAMPLE_OK") != null);
}
