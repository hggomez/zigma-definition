//! Tests for the generation of server.ts, the HTTP layer of the TS backend,
//! driving `ts_server_generator.zig`. Plain Node (`node:http`, no framework);
//! the server is generated from the SSOT like dml.ts, with an explicit route
//! per entity and operation. The API lives under /api/<entity>; the pk (and
//! later the filters) goes in the query string. Every response is JSON: a
//! list is a bare array, an error is `{ "error": ... }`.
//!
//! First step: only the list (GET /api/<entity>), and only for the entities
//! the generator is given (aida's server starts with `periodos` alone).

const std = @import("std");
const aida = @import("aida");
const ts = @import("ts_server_generator");
const expectEqualStrings = std.testing.expectEqualStrings;

test "generateTsServer: GET /api/<entity> lists the rows as a JSON array, anything else is a JSON 404" {
    try expectEqualStrings(
        \\import { createServer, type ServerResponse } from "node:http";
        \\import pg from "pg";
        \\
        \\import { selectAllPeriodos } from "./dml.ts";
        \\
        \\const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
        \\
        \\function json(res: ServerResponse, status: number, body: unknown): void {
        \\  res.writeHead(status, { "Content-Type": "application/json" });
        \\  res.end(JSON.stringify(body));
        \\}
        \\
        \\const server = createServer(async (req, res) => {
        \\  const url = new URL(req.url ?? "/", "http://localhost");
        \\  try {
        \\    if (req.method === "GET" && url.pathname === "/api/periodos") {
        \\      const q = selectAllPeriodos();
        \\      const { rows } = await pool.query(q.text, q.values);
        \\      return json(res, 200, rows);
        \\    }
        \\    return json(res, 404, { error: "not found" });
        \\  } catch (err) {
        \\    console.error(err);
        \\    return json(res, 500, { error: "internal error" });
        \\  }
        \\});
        \\
        \\server.listen(Number(process.env.PORT ?? 3000));
        \\
    , ts.generateTsServer(.{ .periodos = aida.periodos }));
}

test "generateTsServer: one route per entity, in declaration order, all imported from dml.ts" {
    const server = ts.generateTsServer(.{ .periodos = aida.periodos, .materias = aida.materias });
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\import { selectAllPeriodos, selectAllMaterias } from "./dml.ts";
    ) != null);
    const periodos_route = std.mem.indexOf(u8, server, "url.pathname === \"/api/periodos\"").?;
    const materias_route = std.mem.indexOf(u8, server, "url.pathname === \"/api/materias\"").?;
    try std.testing.expect(periodos_route < materias_route);
    try std.testing.expect(std.mem.indexOf(u8, server, "const q = selectAllMaterias();") != null);
}
