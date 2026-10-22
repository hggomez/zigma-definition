//! The generated frontend end to end: the `frontend` service of
//! docker-compose.yml (nginx serving the generated pages and proxying /api to
//! the backend) checked in a real headless browser by the `e2e` service
//! (Playwright, e2e/tests/frontend.spec.ts), all inside Docker.
//!
//! The test seeds rows straight into Postgres (psql inside the postgres
//! container) with the marker "e2e-test" (a clase whose `orden` is 2^53 + 1,
//! and another one without `fecha`), runs the Playwright suite with
//! `docker compose run --rm e2e`, and removes the rows afterwards.
//!
//! Run with `zig build frontend-e2e`, which regenerates dml.ts, server.ts and
//! the frontend, applies the aida schema, builds the images and brings the
//! frontend up (and the backend with it). Not part of `zig build test` (needs
//! Docker).

const std = @import("std");

fn run(argv: []const []const u8) !std.process.RunResult {
    return std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = argv,
        .stdout_limit = .limited(1 << 22),
        .stderr_limit = .limited(1 << 22),
    });
}

fn psql(sql: []const u8) !void {
    const result = try run(&.{ "docker", "exec", "zigma_aida_postgres", "psql", "-U", "aida", "-d", "aida", "-v", "ON_ERROR_STOP=1", "-c", sql });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print("psql failed: {s}\n", .{result.stderr});
        return error.PsqlFailed;
    }
}

// Every row the test writes, keyed by the same value; removed child-first.
const cleanup =
    \\DELETE FROM clases WHERE periodo = 'e2e-test';
    \\DELETE FROM cursos WHERE periodo = 'e2e-test';
    \\DELETE FROM materias WHERE materia = 'e2e-test';
    \\DELETE FROM periodos WHERE periodo = 'e2e-test';
;

const seed =
    \\INSERT INTO periodos (periodo) VALUES ('e2e-test');
    \\INSERT INTO materias (materia, denominacion) VALUES ('e2e-test', 'e2e-test');
    \\INSERT INTO cursos (periodo, materia) VALUES ('e2e-test', 'e2e-test');
    \\INSERT INTO clases (periodo, materia, orden, fecha, tema) VALUES
    \\  ('e2e-test', 'e2e-test', 9007199254740993, ROW(2026, 3, 14), NULL),
    \\  ('e2e-test', 'e2e-test', 1, NULL, 'sin fecha');
;

test "the generated frontend, in a headless browser, navigates and lists the aida entities" {
    try psql(cleanup);
    try psql(seed);
    defer psql(cleanup) catch {};

    const result = try run(&.{ "docker", "compose", "run", "--rm", "e2e" });
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print(
            "the e2e suite exited {any}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
            .{ result.term, result.stdout, result.stderr },
        );
        return error.FrontendE2eFailed;
    }
}
