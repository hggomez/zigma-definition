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
//! Operations, for every entity: the list (GET /api/<entity>, no query
//! string), one row (GET /api/<entity>?<full pk>: the object, or a JSON 404),
//! delete (DELETE /api/<entity>?<full pk>: 204 without a body, or a JSON 404),
//! create (POST /api/<entity>, the row as a JSON body: 201 without a body) and,
//! when the entity has some field outside the pk, update (PUT
//! /api/<entity>?<full pk>, the fields outside the pk as a JSON body: 204, or
//! a JSON 404; the full row: an absent nullable field is written as null).
//!
//! The query string must have every parameter of the pk exactly once and
//! nothing else, or it is a 400; a struct of the pk is one parameter per field
//! (`fecha.año=…&fecha.mes=…`). Each value is then read by its type
//! (`pk<Entity>`): text as is, an integer as decimal digits inside the
//! interval of its Zig type (exact, as a bigint; else a 400), a struct as the
//! composite's literal `(…,…)` that Postgres reads.
//!
//! A body is read in the same format the responses use (`readBody` keeps
//! every JSON number as its exact text, so a bigint never goes through a JS
//! number): a JSON object with only the fields it takes (`row<Entity>` for a
//! create: every field; `set<Entity>` for an update: the fields outside the
//! pk, which only goes in the query string), each read by its type: a string,
//! a boolean, an integer inside its interval, a struct as an object with
//! exactly its fields (`read<Domain>`, sent to Postgres as the composite's
//! literal). A nullable field (outside the pk) may be null or absent (taken as
//! null), the others are required; anything else is a 400 naming the field
//! (`fecha.mes` inside a struct). A Postgres rejection (a duplicate pk, a
//! referenced row) is, for now, the generic 500: pk/uk/fk violations are
//! handled together later.

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
        \\// An integer from its decimal text, inside min..max, exact (as a bigint);
        \\// null when the text is not one.
        \\function readInteger(text: string, min: bigint, max: bigint): bigint | null {
        \\  if (!/^-?[0-9]+$/.test(text)) return null;
        \\  const n = BigInt(text);
        \\  return n < min || n > max ? null : n;
        \\}
        \\
        \\// A number of a JSON body, kept as its exact text.
        \\class JsonNumber {
        \\  text: string;
        \\  constructor(text: string) {
        \\    this.text = text;
        \\  }
        \\}
        \\
        \\// The body of a request: a JSON object, every number kept as its exact text
        \\// (a JS number would round a bigint).
        \\async function readBody(req: IncomingMessage): Promise<{ object: Record<string, unknown> } | { error: string }> {
        \\  const chunks: Buffer[] = [];
        \\  for await (const chunk of req) chunks.push(chunk);
        \\  let body: unknown;
        \\  try {
        \\    body = JSON.parse(Buffer.concat(chunks).toString("utf8"), (key, value, context) => (typeof value === "number" ? new JsonNumber(context.source) : value));
        \\  } catch {
        \\    return { error: "body is not valid JSON" };
        \\  }
        \\  if (typeof body !== "object" || body === null || Array.isArray(body) || body instanceof JsonNumber) return { error: "body must be a JSON object" };
        \\  return { object: body as Record<string, unknown> };
        \\}
        \\
        \\type Read = { value: any } | { error: string };
        \\
        \\// A field of a JSON object, read by `read`; absent or null is null when the
        \\// field is nullable, an error otherwise.
        \\function readField(o: Record<string, unknown>, key: string, name: string, nullable: boolean, read: (v: unknown, name: string) => Read): Read {
        \\  const v = o[key];
        \\  if (v === undefined || v === null) {
        \\    if (nullable) return { value: null };
        \\    return { error: v === undefined ? `missing field '${name}'` : `field '${name}' must not be null` };
        \\  }
        \\  return read(v, name);
        \\}
        \\
        \\// A field of a JSON object other than `keys`, as an error; null when there is none.
        \\function unknownField(o: Record<string, unknown>, keys: string[], prefix: string): Read | null {
        \\  const extra = Object.keys(o).find((key) => !keys.includes(key));
        \\  return extra === undefined ? null : { error: `unknown field '${prefix}${extra}'` };
        \\}
        \\
        \\function readText(v: unknown, name: string): Read {
        \\  return typeof v === "string" ? { value: v } : { error: `field '${name}' must be a string` };
        \\}
        \\
        \\function readBoolean(v: unknown, name: string): Read {
        \\  return typeof v === "boolean" ? { value: v } : { error: `field '${name}' must be a boolean` };
        \\}
        \\
        \\// An integer of a JSON body inside min..max: exact, as a bigint.
        \\function readBigint(v: unknown, name: string, min: bigint, max: bigint): Read {
        \\  const n = v instanceof JsonNumber ? readInteger(v.text, min, max) : null;
        \\  return n === null ? { error: `field '${name}' must be an integer in ${min}..${max}` } : { value: n };
        \\}
        \\
        \\// An integer of a JSON body inside min..max, as a number.
        \\function readNumber(v: unknown, name: string, min: bigint, max: bigint): Read {
        \\  const n = readBigint(v, name, min, max);
        \\  return "error" in n ? n : { value: Number(n.value) };
        \\}
        \\
        \\function encodePeriodos(row: any): unknown {
        \\  return { periodo: row.periodo };
        \\}
        \\
        \\// The pk of periodos from its query-string values, each read by its type.
        \\function pkPeriodos(v: Record<string, string>): { value: any } | { error: string } {
        \\  return { value: { periodo: v["periodo"] } };
        \\}
        \\
        \\// A row of periodos from a JSON body: only its fields, each read by its type.
        \\function rowPeriodos(o: Record<string, unknown>): Read {
        \\  const extra = unknownField(o, ["periodo"], "");
        \\  if (extra !== null) return extra;
        \\  const periodo = readField(o, "periodo", "periodo", false, readText);
        \\  if ("error" in periodo) return periodo;
        \\  return { value: { periodo: periodo.value } };
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
        \\      const key = pkPeriodos(pk.values);
        \\      if ("error" in key) return json(res, 400, { error: key.error });
        \\      const q = selectPeriodosByPk(key.value);
        \\      const { rows } = await pool.query(q.text, q.values);
        \\      if (rows.length === 0) return json(res, 404, { error: "not found" });
        \\      return json(res, 200, encodePeriodos(rows[0]));
        \\    }
        \\    if (req.method === "DELETE" && url.pathname === "/api/periodos") {
        \\      const pk = readPk(url.searchParams, ["periodo"]);
        \\      if ("error" in pk) return json(res, 400, { error: pk.error });
        \\      const key = pkPeriodos(pk.values);
        \\      if ("error" in key) return json(res, 400, { error: key.error });
        \\      const q = deletePeriodos(key.value);
        \\      const { rowCount } = await pool.query(q.text, q.values);
        \\      if (rowCount === 0) return json(res, 404, { error: "not found" });
        \\      res.writeHead(204);
        \\      return res.end();
        \\    }
        \\    if (req.method === "POST" && url.pathname === "/api/periodos") {
        \\      const body = await readBody(req);
        \\      if ("error" in body) return json(res, 400, { error: body.error });
        \\      const row = rowPeriodos(body.object);
        \\      if ("error" in row) return json(res, 400, { error: row.error });
        \\      const q = insertPeriodos(row.value);
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
        \\// The pk of cursos from its query-string values, each read by its type.
        \\function pkCursos(v: Record<string, string>): { value: any } | { error: string } {
        \\  return { value: { periodo: v["periodo"], materia: v["materia"] } };
        \\}
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\      const pk = readPk(url.searchParams, ["periodo", "materia"]);
        \\      if ("error" in pk) return json(res, 400, { error: pk.error });
        \\      const key = pkCursos(pk.values);
        \\      if ("error" in key) return json(res, 400, { error: key.error });
        \\      const q = selectCursosByPk(key.value);
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\    if (req.method === "DELETE" && url.pathname === "/api/cursos") {
        \\      const pk = readPk(url.searchParams, ["periodo", "materia"]);
        \\      if ("error" in pk) return json(res, 400, { error: pk.error });
        \\      const key = pkCursos(pk.values);
        \\      if ("error" in key) return json(res, 400, { error: key.error });
        \\      const q = deleteCursos(key.value);
    ) != null);
}

test "generateTsServer: a bigint in the pk read as decimal digits inside the i64 interval, exact" {
    const server = ts.generateTsServer(aida.type_defs, .{ .clases = aida.clases });
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\import { selectAllClases, selectClasesByPk, deleteClases, insertClases, updateClases } from "./dml.ts";
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\// The pk of clases from its query-string values, each read by its type.
        \\function pkClases(v: Record<string, string>): { value: any } | { error: string } {
        \\  const orden = readInteger(v["orden"], -9223372036854775808n, 9223372036854775807n);
        \\  if (orden === null) return { error: "field 'orden' must be an integer in -9223372036854775808..9223372036854775807" };
        \\  return { value: { periodo: v["periodo"], materia: v["materia"], orden: orden } };
        \\}
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\      const pk = readPk(url.searchParams, ["periodo", "materia", "orden"]);
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server, "const q = deleteClases(key.value);") != null);
}

test "generateTsServer: a struct in the pk, one parameter per field, sent to Postgres as the composite's literal" {
    const server = ts.generateTsServer(aida.type_defs, .{ .mesas = aida.mesas });
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\// The pk of mesas from its query-string values, each read by its type.
        \\function pkMesas(v: Record<string, string>): { value: any } | { error: string } {
        \\  const fecha_año = readInteger(v["fecha.año"], 0n, 65535n);
        \\  if (fecha_año === null) return { error: "field 'fecha.año' must be an integer in 0..65535" };
        \\  const fecha_mes = readInteger(v["fecha.mes"], 0n, 255n);
        \\  if (fecha_mes === null) return { error: "field 'fecha.mes' must be an integer in 0..255" };
        \\  const fecha_día = readInteger(v["fecha.día"], 0n, 255n);
        \\  if (fecha_día === null) return { error: "field 'fecha.día' must be an integer in 0..255" };
        \\  return { value: { periodo: v["periodo"], materia: v["materia"], fecha: `(${fecha_año},${fecha_mes},${fecha_día})` } };
        \\}
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\      const pk = readPk(url.searchParams, ["periodo", "materia", "fecha.año", "fecha.mes", "fecha.día"]);
    ) != null);
}

test "generateTsServer: create reads every field of the entity, the nullable ones may be absent" {
    const server = ts.generateTsServer(aida.type_defs, .{ .docentes = aida.docentes });
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\// A row of docentes from a JSON body: only its fields, each read by its type.
        \\function rowDocentes(o: Record<string, unknown>): Read {
        \\  const extra = unknownField(o, ["docente", "apellido", "nombres", "cargo", "email", "email_alternativo", "jefe"], "");
        \\  if (extra !== null) return extra;
        \\  const docente = readField(o, "docente", "docente", false, readText);
        \\  if ("error" in docente) return docente;
        \\  const apellido = readField(o, "apellido", "apellido", false, readText);
        \\  if ("error" in apellido) return apellido;
        \\  const nombres = readField(o, "nombres", "nombres", false, readText);
        \\  if ("error" in nombres) return nombres;
        \\  const cargo = readField(o, "cargo", "cargo", true, readText);
        \\  if ("error" in cargo) return cargo;
        \\  const email = readField(o, "email", "email", true, readText);
        \\  if ("error" in email) return email;
        \\  const email_alternativo = readField(o, "email_alternativo", "email_alternativo", true, readText);
        \\  if ("error" in email_alternativo) return email_alternativo;
        \\  const jefe = readField(o, "jefe", "jefe", true, readText);
        \\  if ("error" in jefe) return jefe;
        \\  return { value: { docente: docente.value, apellido: apellido.value, nombres: nombres.value, cargo: cargo.value, email: email.value, email_alternativo: email_alternativo.value, jefe: jefe.value } };
        \\}
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\    if (req.method === "POST" && url.pathname === "/api/docentes") {
        \\      const body = await readBody(req);
        \\      if ("error" in body) return json(res, 400, { error: body.error });
        \\      const row = rowDocentes(body.object);
        \\      if ("error" in row) return json(res, 400, { error: row.error });
        \\      const q = insertDocentes(row.value);
    ) != null);
}

test "generateTsServer: update takes the pk from the query string and the other fields from the body" {
    const server = ts.generateTsServer(aida.type_defs, .{ .materias = aida.materias });
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\// The fields outside the pk of materias from a JSON body: only those, each read by its type.
        \\function setMaterias(o: Record<string, unknown>): Read {
        \\  const extra = unknownField(o, ["denominacion"], "");
        \\  if (extra !== null) return extra;
        \\  const denominacion = readField(o, "denominacion", "denominacion", false, readText);
        \\  if ("error" in denominacion) return denominacion;
        \\  return { value: { denominacion: denominacion.value } };
        \\}
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\    if (req.method === "PUT" && url.pathname === "/api/materias") {
        \\      const pk = readPk(url.searchParams, ["materia"]);
        \\      if ("error" in pk) return json(res, 400, { error: pk.error });
        \\      const key = pkMaterias(pk.values);
        \\      if ("error" in key) return json(res, 400, { error: key.error });
        \\      const body = await readBody(req);
        \\      if ("error" in body) return json(res, 400, { error: body.error });
        \\      const row = setMaterias(body.object);
        \\      if ("error" in row) return json(res, 400, { error: row.error });
        \\      const q = updateMaterias(key.value, row.value);
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
        \\  const extra = unknownField(o, ["docente"], "");
        \\  if (extra !== null) return extra;
        \\  const docente = readField(o, "docente", "docente", true, readText);
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server, "const q = updateCursos(key.value, row.value);") != null);
}

test "generateTsServer: no update route for an entity that is all pk" {
    const server = ts.generateTsServer(aida.type_defs, .{ .periodos = aida.periodos, .inscripciones = aida.inscripciones });
    try std.testing.expect(std.mem.indexOf(u8, server, "\"PUT\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, server, "update") == null);
    try std.testing.expect(std.mem.indexOf(u8, server, "function set") == null);
}

test "generateTsServer: a body with a bigint and a struct, each read by its type; a struct sent as the composite's literal" {
    const server = ts.generateTsServer(aida.type_defs, .{ .clases = aida.clases });
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\// fecha from a JSON body: an object with exactly its fields, each read by its
        \\// type, as the composite's literal "(…,…)" that Postgres reads.
        \\function readFecha(v: unknown, name: string): Read {
        \\  if (typeof v !== "object" || v === null || Array.isArray(v) || v instanceof JsonNumber) return { error: `field '${name}' must be an object` };
        \\  const o = v as Record<string, unknown>;
        \\  const extra = unknownField(o, ["año", "mes", "día"], `${name}.`);
        \\  if (extra !== null) return extra;
        \\  const año = readField(o, "año", `${name}.año`, false, (v, name) => readNumber(v, name, 0n, 65535n));
        \\  if ("error" in año) return año;
        \\  const mes = readField(o, "mes", `${name}.mes`, false, (v, name) => readNumber(v, name, 0n, 255n));
        \\  if ("error" in mes) return mes;
        \\  const día = readField(o, "día", `${name}.día`, false, (v, name) => readNumber(v, name, 0n, 255n));
        \\  if ("error" in día) return día;
        \\  return { value: `(${año.value},${mes.value},${día.value})` };
        \\}
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\// A row of clases from a JSON body: only its fields, each read by its type.
        \\function rowClases(o: Record<string, unknown>): Read {
        \\  const extra = unknownField(o, ["periodo", "materia", "orden", "fecha", "tema"], "");
        \\  if (extra !== null) return extra;
        \\  const periodo = readField(o, "periodo", "periodo", false, readText);
        \\  if ("error" in periodo) return periodo;
        \\  const materia = readField(o, "materia", "materia", false, readText);
        \\  if ("error" in materia) return materia;
        \\  const orden = readField(o, "orden", "orden", false, (v, name) => readBigint(v, name, -9223372036854775808n, 9223372036854775807n));
        \\  if ("error" in orden) return orden;
        \\  const fecha = readField(o, "fecha", "fecha", true, readFecha);
        \\  if ("error" in fecha) return fecha;
        \\  const tema = readField(o, "tema", "tema", true, readText);
        \\  if ("error" in tema) return tema;
        \\  return { value: { periodo: periodo.value, materia: materia.value, orden: orden.value, fecha: fecha.value, tema: tema.value } };
        \\}
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\// The fields outside the pk of clases from a JSON body: only those, each read by its type.
        \\function setClases(o: Record<string, unknown>): Read {
        \\  const extra = unknownField(o, ["fecha", "tema"], "");
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server, "const q = insertClases(row.value);") != null);
    try std.testing.expect(std.mem.indexOf(u8, server, "const q = updateClases(key.value, row.value);") != null);
}

// Every kind of field: a bigint pk, a struct with a bigint, a boolean and a
// narrow integer inside, a nullable bigint, a boolean.
const Medida = struct { total: i64, ok: bool, nivel: u8 };

const types = zigma.defineTypes(.{
    .text = zigma.TypeDef{ .Type = []const u8 },
    .integer = zigma.TypeDef{ .Type = i64 },
    .boolean = zigma.TypeDef{ .Type = bool },
    .small = zigma.TypeDef{ .Type = u8 },
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

// A narrow integer in the pk: a JS number once read.
const niveles = zigma.defineEntity(.{
    .pk = .{"nivel"},
    .fields = zigma.record(types, .{
        .nivel = .{ .type = "small" },
        .nombre = .{ .type = "text" },
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
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\function encodeLecturas(row: any): unknown {
        \\  return { id: JSON.rawJSON(row.id), medida: row.medida === null ? null : decodeMedida(row.medida), cantidad: row.cantidad === null ? null : JSON.rawJSON(row.cantidad), activo: row.activo };
        \\}
        \\
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server, "return json(res, 200, rows.map(encodeLecturas));") != null);
}

test "generateTsServer: a body field of every kind, a struct with a bigint, a boolean and a narrow integer inside" {
    const server = ts.generateTsServer(types, .{ .lecturas = lecturas });
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\  const total = readField(o, "total", `${name}.total`, false, (v, name) => readBigint(v, name, -9223372036854775808n, 9223372036854775807n));
        \\  if ("error" in total) return total;
        \\  const ok = readField(o, "ok", `${name}.ok`, false, readBoolean);
        \\  if ("error" in ok) return ok;
        \\  const nivel = readField(o, "nivel", `${name}.nivel`, false, (v, name) => readNumber(v, name, 0n, 255n));
        \\  if ("error" in nivel) return nivel;
        \\  return { value: `(${total.value},${ok.value},${nivel.value})` };
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\  const id = readField(o, "id", "id", false, (v, name) => readBigint(v, name, -9223372036854775808n, 9223372036854775807n));
        \\  if ("error" in id) return id;
        \\  const medida = readField(o, "medida", "medida", true, readMedida);
        \\  if ("error" in medida) return medida;
        \\  const cantidad = readField(o, "cantidad", "cantidad", true, (v, name) => readBigint(v, name, -9223372036854775808n, 9223372036854775807n));
        \\  if ("error" in cantidad) return cantidad;
        \\  const activo = readField(o, "activo", "activo", false, readBoolean);
    ) != null);
}

test "generateTsServer: a narrow integer in the pk is read inside its interval, then as a number" {
    const server = ts.generateTsServer(types, .{ .niveles = niveles });
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\function pkNiveles(v: Record<string, string>): { value: any } | { error: string } {
        \\  const nivel = readInteger(v["nivel"], 0n, 255n);
        \\  if (nivel === null) return { error: "field 'nivel' must be an integer in 0..255" };
        \\  return { value: { nivel: Number(nivel) } };
        \\}
    ) != null);
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
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\function encodeClases(row: any): unknown {
        \\  return { periodo: row.periodo, materia: row.materia, orden: JSON.rawJSON(row.orden), fecha: row.fecha === null ? null : decodeFecha(row.fecha), tema: row.tema };
        \\}
        \\
    ) != null);
}

test "generateTsServer: one route and one encoder per entity, in declaration order; each struct decoder and reader once" {
    const server = ts.generateTsServer(aida.type_defs, .{ .periodos = aida.periodos, .clases = aida.clases, .mesas = aida.mesas });
    try std.testing.expect(std.mem.indexOf(u8, server,
        \\import { selectAllPeriodos, selectPeriodosByPk, deletePeriodos, insertPeriodos, selectAllClases, selectClasesByPk, deleteClases, insertClases, updateClases, selectAllMesas, selectMesasByPk, deleteMesas, insertMesas, updateMesas } from "./dml.ts";
    ) != null);
    const periodos_route = std.mem.indexOf(u8, server, "url.pathname === \"/api/periodos\"").?;
    const clases_route = std.mem.indexOf(u8, server, "url.pathname === \"/api/clases\"").?;
    const mesas_route = std.mem.indexOf(u8, server, "url.pathname === \"/api/mesas\"").?;
    try std.testing.expect(periodos_route < clases_route and clases_route < mesas_route);
    try std.testing.expect(std.mem.count(u8, server, "function decodeFecha(") == 1);
    try std.testing.expect(std.mem.count(u8, server, "function readFecha(") == 1);
    try std.testing.expect(std.mem.indexOf(u8, server, "function encodeMesas(") != null);
}
