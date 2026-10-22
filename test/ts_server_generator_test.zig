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
//! and delete (DELETE /api/<entity>?<full pk>: 204 without a body, or a JSON
//! 404 when no row had that pk) for the entities whose pk is text only (a pk
//! of another type would need its value parsed from the query string: not
//! yet). The query string must have every field of the pk exactly once and
//! nothing else, or it is a 400. A delete that Postgres rejects (a referenced
//! row) is, for now, the generic 500: pk/uk/fk violations are handled
//! together later.
//!
//! Create (POST /api/<entity>, the row as a JSON body: 201 without a body)
//! for the entities whose fields are all text (a bigint or a fecha in a body
//! would need the TS -> Postgres translation: not yet). The body must be a
//! JSON object with only the entity's fields, each a string; a nullable field
//! may be null or absent (taken as null), the others are required; anything
//! else is a 400. A duplicate pk is, for now, the generic 500.
//!
//! Update (PUT /api/<entity>?<full pk>, the fields outside the pk as a JSON
//! body: 204 without a body, or a JSON 404 when no row had that pk) for the
//! entities with a text-only pk, text-only fields and some field outside the
//! pk (an all-pk entity has nothing to update). The update is the full row:
//! a nullable field the body leaves out is written as null; a pk field in the
//! body is an unknown field (the pk is only in the query string).

const std = @import("std");
const zigma = @import("zigma");
const aida = @import("aida");
const ts = @import("ts_server_generator");
const expectEqualStrings = std.testing.expectEqualStrings;

test "generateTsServer: the list, one row and delete with the full pk, create with a JSON body, anything else a JSON 404" {
    try expectEqualStrings(
        \\import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
        \\import pg from "pg";
        \\
        \\import { selectAllPeriodos, selectPeriodosByPk, deletePeriodos, insertPeriodos } from "./dml.ts";
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
        \\// The body of a request as a row of an entity whose fields are all text: a
        \\// JSON object with only its fields, each a string; a nullable field may be
        \\// null or absent (taken as null), the others are required.
        \\async function readBody(req: IncomingMessage, fields: Record<string, boolean>): Promise<{ values: Record<string, string | null> } | { error: string }> {
        \\  const chunks: Buffer[] = [];
        \\  for await (const chunk of req) chunks.push(chunk);
        \\  let body: unknown;
        \\  try {
        \\    body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
        \\  } catch {
        \\    return { error: "body is not valid JSON" };
        \\  }
        \\  if (typeof body !== "object" || body === null || Array.isArray(body)) return { error: "body must be a JSON object" };
        \\  const object = body as Record<string, unknown>;
        \\  for (const name of Object.keys(object)) {
        \\    if (!(name in fields)) return { error: `unknown field '${name}'` };
        \\  }
        \\  const values: Record<string, string | null> = {};
        \\  for (const [name, nullable] of Object.entries(fields)) {
        \\    const value = object[name];
        \\    if (value === undefined && !nullable) return { error: `missing field '${name}'` };
        \\    if (value === null && !nullable) return { error: `field '${name}' must not be null` };
        \\    if (value !== undefined && value !== null && typeof value !== "string") return { error: `field '${name}' must be a string` };
        \\    values[name] = (value ?? null) as string | null;
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
        \\    if (req.method === "DELETE" && url.pathname === "/api/periodos") {
        \\      const pk = readPk(url.searchParams, ["periodo"]);
        \\      if ("error" in pk) return json(res, 400, { error: pk.error });
        \\      const q = deletePeriodos({ periodo: pk.values.periodo });
        \\      const { rowCount } = await pool.query(q.text, q.values);
        \\      if (rowCount === 0) return json(res, 404, { error: "not found" });
        \\      res.writeHead(204);
        \\      return res.end();
        \\    }
        \\    if (req.method === "POST" && url.pathname === "/api/periodos") {
        \\      const body = await readBody(req, { periodo: false });
        \\      if ("error" in body) return json(res, 400, { error: body.error });
        \\      const q = insertPeriodos({ periodo: body.values.periodo });
        \\      await pool.query(q.text, q.values);
        \\      res.writeHead(201);
        \\      return res.end();
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

test "generateTsServer: one row and delete with a composite text pk, every pk field passed in pk order" {
    const server = ts.generateTsServer(aida.type_defs, .{ .cursos = aida.cursos });
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\      const pk = readPk(url.searchParams, ["periodo", "materia"]);
        \\      if ("error" in pk) return json(res, 400, { error: pk.error });
        \\      const q = selectCursosByPk({ periodo: pk.values.periodo, materia: pk.values.materia });
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\    if (req.method === "DELETE" && url.pathname === "/api/cursos") {
        \\      const pk = readPk(url.searchParams, ["periodo", "materia"]);
        \\      if ("error" in pk) return json(res, 400, { error: pk.error });
        \\      const q = deleteCursos({ periodo: pk.values.periodo, materia: pk.values.materia });
    ) != null);
}

test "generateTsServer: create reads every field of the entity, the nullable ones may be absent" {
    const server = ts.generateTsServer(aida.type_defs, .{ .docentes = aida.docentes });
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\    if (req.method === "POST" && url.pathname === "/api/docentes") {
        \\      const body = await readBody(req, { docente: false, apellido: false, nombres: false, cargo: true, email: true, email_alternativo: true, jefe: true });
        \\      if ("error" in body) return json(res, 400, { error: body.error });
        \\      const q = insertDocentes({ docente: body.values.docente, apellido: body.values.apellido, nombres: body.values.nombres, cargo: body.values.cargo, email: body.values.email, email_alternativo: body.values.email_alternativo, jefe: body.values.jefe });
    ) != null);
}

test "generateTsServer: update takes the pk from the query string and the other fields from the body" {
    const server = ts.generateTsServer(aida.type_defs, .{ .materias = aida.materias });
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\    if (req.method === "PUT" && url.pathname === "/api/materias") {
        \\      const pk = readPk(url.searchParams, ["materia"]);
        \\      if ("error" in pk) return json(res, 400, { error: pk.error });
        \\      const body = await readBody(req, { denominacion: false });
        \\      if ("error" in body) return json(res, 400, { error: body.error });
        \\      const q = updateMaterias({ materia: pk.values.materia }, { denominacion: body.values.denominacion });
        \\      const { rowCount } = await pool.query(q.text, q.values);
        \\      if (rowCount === 0) return json(res, 404, { error: "not found" });
        \\      res.writeHead(204);
        \\      return res.end();
        \\    }
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server, "updateMaterias } from \"./dml.ts\";") != null);
}

test "generateTsServer: update with a composite pk and a nullable field" {
    const server = ts.generateTsServer(aida.type_defs, .{ .cursos = aida.cursos });
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\      const body = await readBody(req, { docente: true });
        \\      if ("error" in body) return json(res, 400, { error: body.error });
        \\      const q = updateCursos({ periodo: pk.values.periodo, materia: pk.values.materia }, { docente: body.values.docente });
    ) != null);
}

test "generateTsServer: no update route for an entity that is all pk" {
    const server = ts.generateTsServer(aida.type_defs, .{ .periodos = aida.periodos, .inscripciones = aida.inscripciones });
    try std.testing.expect(std.mem.indexOf(u8, server, "\"PUT\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, server, "update") == null);
}

test "generateTsServer: no one-row nor delete route (yet) for an entity whose pk is not text only" {
    const server = ts.generateTsServer(aida.type_defs, .{ .clases = aida.clases });
    try std.testing.expect(std.mem.indexOf(u8, server, "selectClasesByPk") == null);
    try std.testing.expect(std.mem.indexOf(u8, server, "deleteClases") == null);
    try std.testing.expect(std.mem.indexOf(u8, server, "insertClases") == null);
    try std.testing.expect(std.mem.indexOf(u8, server, "updateClases") == null);
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
        \\import { selectAllPeriodos, selectPeriodosByPk, deletePeriodos, insertPeriodos, selectAllClases, selectAllMesas } from "./dml.ts";
    ) != null);
    const periodos_route = std.mem.indexOf(u8, server, "url.pathname === \"/api/periodos\"").?;
    const clases_route = std.mem.indexOf(u8, server, "url.pathname === \"/api/clases\"").?;
    const mesas_route = std.mem.indexOf(u8, server, "url.pathname === \"/api/mesas\"").?;
    try std.testing.expect(periodos_route < clases_route and clases_route < mesas_route);
    try std.testing.expect(std.mem.count(u8, server, "function decodeFecha(") == 1);
    try std.testing.expect(std.mem.indexOf(u8, server, "function encodeMesas(") != null);
}
