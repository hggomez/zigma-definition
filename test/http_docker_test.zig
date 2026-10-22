//! The generated HTTP server (backend/src/server.ts) running as the
//! long-running process of the `backend` service of docker-compose.yml, and
//! called over HTTP from the host: GET /api/periodos returns the rows of the
//! real database as a bare JSON array, and an unknown path is a JSON 404.
//!
//! The test seeds one periodo straight into Postgres (psql inside the
//! postgres container), requests the API from the host with Node's fetch,
//! and removes the row afterwards.
//!
//! Run with `zig build http-docker`, which regenerates dml.ts + server.ts
//! into backend/, applies the aida schema, builds the image and brings the
//! backend up (waiting for its healthcheck). Not part of `zig build test`
//! (needs Docker + Node).

const std = @import("std");

const periodo = "http-docker-test";

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

// An ES module run on the host with `node --input-type=module -e`: requests
// the API published by the backend container. Prints HTTP_OK when every
// assert holds.
const script =
    \\import assert from 'node:assert/strict';
    \\const base = 'http://localhost:3000';
    \\
    \\// the list: 200, JSON, a bare array of rows with exactly the entity's fields
    \\let res = await fetch(base + '/api/periodos');
    \\assert.equal(res.status, 200);
    \\assert.match(res.headers.get('content-type') ?? '', /^application\/json/);
    \\const rows = await res.json();
    \\assert.ok(Array.isArray(rows), 'the list is a bare array');
    \\assert.deepEqual(rows.filter((r) => r.periodo === 'http-docker-test'), [{ periodo: 'http-docker-test' }]);
    \\for (const row of rows) assert.deepEqual(Object.keys(row), ['periodo']);
    \\
    \\// an unknown path: 404 with a JSON error
    \\res = await fetch(base + '/api/inexistentes');
    \\assert.equal(res.status, 404);
    \\assert.match(res.headers.get('content-type') ?? '', /^application\/json/);
    \\assert.deepEqual(await res.json(), { error: 'not found' });
    \\
    \\console.log('HTTP_OK');
;

test "the backend container serves GET /api/periodos from the real database" {
    try psql("DELETE FROM periodos WHERE periodo = '" ++ periodo ++ "'");
    try psql("INSERT INTO periodos (periodo) VALUES ('" ++ periodo ++ "')");
    defer psql("DELETE FROM periodos WHERE periodo = '" ++ periodo ++ "'") catch {};

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
