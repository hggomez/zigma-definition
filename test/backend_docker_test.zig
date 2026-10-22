//! The backend running in its own container: the `backend` service of
//! docker-compose.yml (Node + pg + the generated code, built on the host)
//! talks to the `postgres` service by its compose name. The test runs the
//! generated DML builders inside that container, on demand
//! (`docker compose run --rm backend ...`; there is no long-running backend
//! process until the HTTP layer exists), and checks a round-trip.
//!
//! Unlike db_backend_integration_test.zig (Node on the host, Postgres in
//! Docker), nothing here runs on the host but Docker itself.
//!
//! Run with `zig build backend-docker`, which first regenerates dml.ts into
//! backend/, applies the aida schema and builds the backend image. Not part
//! of `zig build test` (needs Docker).

const std = @import("std");

// An ES module run inside the container with `node --input-type=module -e`,
// from the image's working directory (where ./src/dml.ts and pg are). It
// must connect through the compose network (DATABASE_URL names the
// `postgres` service, not localhost), then insert -> selectByPk -> delete.
// Prints ROUNDTRIP_OK on success.
const script =
    \\import assert from 'node:assert/strict';
    \\import { insertPeriodos, selectPeriodosByPk, deletePeriodos } from './src/dml.ts';
    \\import pg from 'pg';
    \\const connectionString = process.env.DATABASE_URL;
    \\assert.match(connectionString ?? '', /@postgres:5432\//, 'DATABASE_URL must name the postgres service');
    \\const pool = new pg.Pool({ connectionString });
    \\const periodo = 'docker-' + Date.now();
    \\try {
    \\  let q = insertPeriodos({ periodo });
    \\  await pool.query(q.text, q.values);
    \\  q = selectPeriodosByPk({ periodo });
    \\  const { rows } = await pool.query(q.text, q.values);
    \\  assert.deepEqual(rows, [{ periodo }]);
    \\  console.log('ROUNDTRIP_OK');
    \\} finally {
    \\  const d = deletePeriodos({ periodo });
    \\  await pool.query(d.text, d.values);
    \\  await pool.end();
    \\}
;

test "the backend container runs the generated DML against the postgres service" {
    const result = std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "docker", "compose", "run", "--rm", "backend", "node", "--input-type=module", "-e", script },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| {
        std.debug.print("could not run docker: {s}\n", .{@errorName(err)});
        return err;
    };
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print(
            "docker compose run exited {any}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
            .{ result.term, result.stdout, result.stderr },
        );
        return error.BackendDockerFailed;
    }

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "ROUNDTRIP_OK") != null);
}
