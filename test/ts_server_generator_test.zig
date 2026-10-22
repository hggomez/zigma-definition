//! Tests for the generation of server.ts, the HTTP layer of the TS backend,
//! driving `ts_server_generator.zig`. Plain Node (`node:http`, no framework);
//! the server is generated from the SSOT like dml.ts, with an explicit route
//! per entity and operation. The API lives under /api/<entity>; the pk (and
//! later the filters) goes in the query string. Every response is JSON: a
//! list is a bare array, an error is `{ "error": ... }`.
//!
//! Each row is encoded field by field from the SSOT (`encode<Entity>`), so
//! every field keeps its type in the JSON. pg gives a BIGINT as a string with
//! its exact value and a composite type as its text form `(…,…)`; from there:
//! - a bigint is an exact JSON number: `JSON.rawJSON` on pg's string (never
//!   through a JS number, which rounds above 2^53);
//! - a struct is an object, read from the composite's text form by
//!   `decode<Domain>`, its fields converted by their type (only numbers,
//!   bigints and booleans for now: text inside a composite has quoting);
//! - a string, a number or a boolean goes as pg gives it;
//! - a nullable field (not in the pk) that needs a conversion keeps null.
//!
//! Operations: the list (GET /api/<entity>, no query string) for every entity
//! given, and one row (GET /api/<entity>?<full pk>: the object, or a JSON 404)
//! for the entities whose pk is text only (a pk of another type would need
//! its value parsed from the query string: not yet). The query string must
//! have every field of the pk exactly once and nothing else, or it is a 400.

const std = @import("std");
const zigma = @import("zigma");
const aida = @import("aida");
const ts = @import("ts_server_generator");
const expectEqualStrings = std.testing.expectEqualStrings;

test "generateTsServer: the list without a query string, one row with the full pk, anything else a JSON 404" {
    try expectEqualStrings(
        \\import { createServer, type ServerResponse } from "node:http";
        \\import pg from "pg";
        \\
        \\import { selectAllPeriodos, selectPeriodosByPk } from "./dml.ts";
        \\
        \\const pool = new pg.Pool({ connectionString: process.env.DATABASE_URL });
        \\
        \\function json(res: ServerResponse, status: number, body: unknown): void {
        \\  res.writeHead(status, { "Content-Type": "application/json" });
        \\  res.end(JSON.stringify(body));
        \\}
        \\
        \\// The pk of a row from the query string: every field of the pk exactly once,
        \\// and nothing else.
        \\function readPk(params: URLSearchParams, pk: string[]): { values: Record<string, string> } | { error: string } {
        \\  const values: Record<string, string> = {};
        \\  for (const [name, value] of params) {
        \\    if (!pk.includes(name)) return { error: `unknown parameter '${name}'` };
        \\    if (name in values) return { error: `repeated parameter '${name}'` };
        \\    values[name] = value;
        \\  }
        \\  for (const name of pk) {
        \\    if (!(name in values)) return { error: `missing pk field '${name}'` };
        \\  }
        \\  return { values };
        \\}
        \\
        \\function encodePeriodos(row: any): unknown {
        \\  return { periodo: row.periodo };
        \\}
        \\
        \\const server = createServer(async (req, res) => {
        \\  const url = new URL(req.url ?? "/", "http://localhost");
        \\  try {
        \\    if (req.method === "GET" && url.pathname === "/api/periodos") {
        \\      if (url.search === "") {
        \\        const q = selectAllPeriodos();
        \\        const { rows } = await pool.query(q.text, q.values);
        \\        return json(res, 200, rows.map(encodePeriodos));
        \\      }
        \\      const pk = readPk(url.searchParams, ["periodo"]);
        \\      if ("error" in pk) return json(res, 400, { error: pk.error });
        \\      const q = selectPeriodosByPk({ periodo: pk.values.periodo });
        \\      const { rows } = await pool.query(q.text, q.values);
        \\      if (rows.length === 0) return json(res, 404, { error: "not found" });
        \\      return json(res, 200, encodePeriodos(rows[0]));
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
    , ts.generateTsServer(aida.type_defs, .{ .periodos = aida.periodos }));
}

test "generateTsServer: one row with a composite text pk, every pk field passed to selectByPk in pk order" {
    const server = ts.generateTsServer(aida.type_defs, .{ .cursos = aida.cursos });
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\      const pk = readPk(url.searchParams, ["periodo", "materia"]);
        \\      if ("error" in pk) return json(res, 400, { error: pk.error });
        \\      const q = selectCursosByPk({ periodo: pk.values.periodo, materia: pk.values.materia });
    ) != null);
}

test "generateTsServer: no one-row route (yet) for an entity whose pk is not text only" {
    const server = ts.generateTsServer(aida.type_defs, .{ .clases = aida.clases });
    try std.testing.expect(std.mem.indexOf(u8, server, "selectClasesByPk") == null);
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\    if (req.method === "GET" && url.pathname === "/api/clases") {
        \\      const q = selectAllClases();
    ) != null);
}

// Every kind of field: a bigint pk, a struct with a bigint, a boolean and a
// narrow integer inside, a nullable bigint, a boolean.
const Medida = struct { total: i64, ok: bool, nivel: u8 };

const types = zigma.defineTypes(.{
    .text = zigma.TypeDef{ .Type = []const u8 },
    .integer = zigma.TypeDef{ .Type = i64 },
    .boolean = zigma.TypeDef{ .Type = bool },
    .medida = zigma.TypeDef{ .Type = Medida },
});

const lecturas = zigma.defineEntity(.{
    .pk = .{"id"},
    .fields = zigma.record(types, .{
        .id = .{ .type = "integer" },
        .medida = .{ .type = "medida" },
        .cantidad = .{ .type = "integer" },
        .activo = .{ .type = "boolean", .nullable = false },
    }),
});

test "generateTsServer: each field encoded by its type, a struct decoded from the composite's text form" {
    const server = ts.generateTsServer(types, .{ .lecturas = lecturas });
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\// medida: a composite type, read from its text form "(…,…)"
        \\function decodeMedida(text: string): unknown {
        \\  const f = text.slice(1, -1).split(",");
        \\  return { total: JSON.rawJSON(f[0]), ok: f[1] === "t", nivel: Number(f[2]) };
        \\}
        \\
        \\function encodeLecturas(row: any): unknown {
        \\  return { id: JSON.rawJSON(row.id), medida: row.medida === null ? null : decodeMedida(row.medida), cantidad: row.cantidad === null ? null : JSON.rawJSON(row.cantidad), activo: row.activo };
        \\}
        \\
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server, "return json(res, 200, rows.map(encodeLecturas));") != null);
}

test "generateTsServer: aida's clases, with its bigint orden (pk) and nullable fecha" {
    const server = ts.generateTsServer(aida.type_defs, .{ .clases = aida.clases });
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\// fecha: a composite type, read from its text form "(…,…)"
        \\function decodeFecha(text: string): unknown {
        \\  const f = text.slice(1, -1).split(",");
        \\  return { año: Number(f[0]), mes: Number(f[1]), día: Number(f[2]) };
        \\}
        \\
        \\function encodeClases(row: any): unknown {
        \\  return { periodo: row.periodo, materia: row.materia, orden: JSON.rawJSON(row.orden), fecha: row.fecha === null ? null : decodeFecha(row.fecha), tema: row.tema };
        \\}
        \\
    ) != null);
}

test "generateTsServer: one route and one encoder per entity, in declaration order; each struct decoder once" {
    const server = ts.generateTsServer(aida.type_defs, .{ .periodos = aida.periodos, .clases = aida.clases, .mesas = aida.mesas });
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\import { selectAllPeriodos, selectPeriodosByPk, selectAllClases, selectAllMesas } from "./dml.ts";
    ) != null);
    const periodos_route = std.mem.indexOf(u8, server, "url.pathname === \"/api/periodos\"").?;
    const clases_route = std.mem.indexOf(u8, server, "url.pathname === \"/api/clases\"").?;
    const mesas_route = std.mem.indexOf(u8, server, "url.pathname === \"/api/mesas\"").?;
    try std.testing.expect(periodos_route < clases_route and clases_route < mesas_route);
    try std.testing.expect(std.mem.count(u8, server, "function decodeFecha(") == 1);
    try std.testing.expect(std.mem.indexOf(u8, server, "function encodeMesas(") != null);
}
