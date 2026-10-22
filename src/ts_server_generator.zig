//! server.ts generation: the HTTP layer of the TS backend, from the system's
//! entities. Plain Node (`node:http`, no framework) and `pg`; one explicit
//! route per entity and operation, each calling the builder of dml.ts and
//! running it on the pool. The API lives under /api/<entity>; every response
//! is JSON: a list is a bare array, an error is `{ "error": ... }` (404 for
//! anything without a route, 500 for an exception, which is logged).
//!
//! Each row is encoded field by field from the SSOT (`encode<Entity>`), so
//! every field keeps its type in the JSON. pg gives a BIGINT as a string with
//! its exact value and a composite type as its text form `(…,…)`; from there a
//! bigint is an exact JSON number (`JSON.rawJSON` on pg's string, never
//! through a JS number) and a struct is an object read by `decode<Domain>`
//! (numbers, bigints and booleans inside; text inside a composite is quoted
//! and escaped, so it is not read yet). A nullable field (not in the pk) that
//! needs a conversion keeps null.
//!
//! Operations, for every entity: the list (GET /api/<entity>, no query
//! string), one row (GET /api/<entity>?<full pk>: the object, or a JSON 404)
//! and delete (DELETE /api/<entity>?<full pk>: 204, or a JSON 404). The query
//! string must be exactly the pk (`readPk`; a struct is one parameter per
//! field, `fecha.año=…`), and each value must fit its type (`pk<Entity>`:
//! text as is, an integer as decimal digits inside its Zig interval, a struct
//! sent to Postgres as the composite's literal `(…,…)`); else a JSON 400. A
//! delete Postgres rejects (a referenced row) is, for now, the generic 500:
//! pk/uk/fk violations are handled together later.
//! Create (POST /api/<entity>, the row as a JSON body: 201 without a body) for
//! the entities whose fields are all text; a body that is not a row of the
//! entity (`readBody`) is a JSON 400, a duplicate pk the generic 500. Update
//! (PUT /api/<entity>?<full pk>, the fields outside the pk as a JSON body: 204,
//! or a JSON 404) for the entities with text fields and some field outside
//! the pk; the full row is written (an absent nullable field is null).

const std = @import("std");
const zigma = @import("zigma");
const zig_type_map_ts = @import("zig_type_map_ts");
const ts_backend_generator = @import("ts_backend_generator");
const TsType = zig_type_map_ts.TsType;
const tsTypeOf = zig_type_map_ts.tsTypeOf;
const PascalHolder = ts_backend_generator.PascalHolder;

// The space after `{` is a separate string: a multiline literal would lose it
// as trailing whitespace.
const header_before_imports =
    \\import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
    \\import pg from "pg";
    \\
    \\
++ "import { ";

const header_after_imports =
    \\ } from "./dml.ts";
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
    \\
;

const server_start =
    \\const server = createServer(async (req, res) => {
    \\  const url = new URL(req.url ?? "/", "http://localhost");
    \\  try {
    \\
;

const footer =
    \\    return json(res, 404, { error: "not found" });
    \\  } catch (err) {
    \\    console.error(err);
    \\    return json(res, 500, { error: "internal error" });
    \\  }
    \\});
    \\
    \\server.listen(Number(process.env.PORT ?? 3000));
    \\
;

fn pascal(comptime name: []const u8) []const u8 {
    return &PascalHolder(name).value;
}

/// The TS expression that reads attribute `i` of a composite's text form
/// (`f[i]`, a string) as its JSON value.
fn attributeText(comptime domain: []const u8, comptime field_name: []const u8, comptime t: TsType, comptime i: usize) []const u8 {
    const f = std.fmt.comptimePrint("f[{d}]", .{i});
    return switch (t) {
        .number => "Number(" ++ f ++ ")",
        .bigint => "JSON.rawJSON(" ++ f ++ ")",
        .boolean => f ++ " === \"t\"",
        .string => @compileError("field '" ++ field_name ++ "' of type '" ++ domain ++ "': text inside a composite type is not read yet"),
        .object => @compileError("field '" ++ field_name ++ "' of type '" ++ domain ++ "': a struct inside a composite type is not read yet"),
    };
}

/// `decode<Domain>`: reads a composite type from its text form "(…,…)" into
/// the object of the struct, each attribute by its type.
fn decoderFn(comptime domain: []const u8, comptime fields: []const zig_type_map_ts.TsField) []const u8 {
    var object: []const u8 = "{ ";
    for (fields, 0..) |field, i| {
        const sep = if (i > 0) ", " else "";
        object = object ++ sep ++ field.name ++ ": " ++ attributeText(domain, field.name, field.type, i);
    }
    return "// " ++ domain ++ ": a composite type, read from its text form \"(…,…)\"\n" ++
        "function decode" ++ pascal(domain) ++ "(text: string): unknown {\n" ++
        "  const f = text.slice(1, -1).split(\",\");\n" ++
        "  return " ++ object ++ " };\n" ++
        "}\n";
}

fn isPkField(comptime entity: anytype, comptime field_name: []const u8) bool {
    for (entity.pk) |pk_field| {
        if (std.mem.eql(u8, pk_field, field_name)) return true;
    }
    return false;
}

/// The TS expression of a field of a row (`row.<field>`, as pg gives it) as
/// its JSON value; null kept for a nullable field that needs a conversion.
fn fieldText(comptime domain: []const u8, comptime field_name: []const u8, comptime t: TsType, comptime nullable: bool) []const u8 {
    const access = "row." ++ field_name;
    const converted = switch (t) {
        .string, .number, .boolean => return access,
        .bigint => "JSON.rawJSON(" ++ access ++ ")",
        .object => "decode" ++ pascal(domain) ++ "(" ++ access ++ ")",
    };
    if (!nullable) return converted;
    return access ++ " === null ? null : " ++ converted;
}

/// `encode<Entity>`: a row as pg gives it -> the JSON object of the entity,
/// with exactly its fields.
fn encoderFn(comptime type_defs: anytype, comptime entity_name: []const u8, comptime entity: anytype) []const u8 {
    const field_names = @typeInfo(@TypeOf(entity.fields)).@"struct".field_names;
    var object: []const u8 = "{ ";
    for (field_names, 0..) |field_name, i| {
        const field = @field(entity.fields, field_name);
        const t = tsTypeOf(@field(type_defs, field.type).Type);
        const nullable = field.nullable and !isPkField(entity, field_name);
        const sep = if (i > 0) ", " else "";
        object = object ++ sep ++ field_name ++ ": " ++ fieldText(field.type, field_name, t, nullable);
    }
    return "function encode" ++ pascal(entity_name) ++ "(row: any): unknown {\n" ++
        "  return " ++ object ++ " };\n" ++
        "}\n";
}

/// The query-string parameters of the pk, in pk order: a field's name, or for
/// a struct one parameter per field (`fecha.año`), quoted for TS.
fn pkParamsText(comptime type_defs: anytype, comptime entity: anytype) []const u8 {
    var out: []const u8 = "";
    for (entity.pk) |pk_field| {
        const t = tsTypeOf(@field(type_defs, @field(entity.fields, pk_field).type).Type);
        if (t == .object) {
            for (t.object) |part| {
                out = out ++ (if (out.len > 0) ", " else "") ++ "\"" ++ pk_field ++ "." ++ part.name ++ "\"";
            }
        } else {
            out = out ++ (if (out.len > 0) ", " else "") ++ "\"" ++ pk_field ++ "\"";
        }
    }
    return out;
}

/// The lines that read an integer parameter `param` into the TS variable
/// `variable`, inside the interval of its Zig type, or return a 400 error.
fn readIntegerText(comptime param: []const u8, comptime variable: []const u8, comptime interval: zig_type_map_ts.Interval) []const u8 {
    const range = std.fmt.comptimePrint("{d}..{d}", .{ interval.min, interval.max });
    const bounds = std.fmt.comptimePrint("{d}n, {d}n", .{ interval.min, interval.max });
    return "  const " ++ variable ++ " = readInteger(v[\"" ++ param ++ "\"], " ++ bounds ++ ");\n" ++
        "  if (" ++ variable ++ " === null) return { error: \"field '" ++ param ++ "' must be an integer in " ++ range ++ "\" };\n";
}

/// `pk<Entity>`: the pk of a row from its query-string values (already
/// checked by `readPk`), each read by its type: text as is, an integer inside
/// its interval (a bigint exact, a narrower one as a number), a struct as the
/// composite's literal `(…,…)` that Postgres reads. A value that does not fit
/// is a 400 error.
fn pkFn(comptime type_defs: anytype, comptime entity_name: []const u8, comptime entity: anytype) []const u8 {
    var checks: []const u8 = "";
    var object: []const u8 = "{ ";
    for (entity.pk, 0..) |pk_field, i| {
        const domain = @field(entity.fields, pk_field).type;
        const t = tsTypeOf(@field(type_defs, domain).Type);
        const value = switch (t) {
            .string => "v[\"" ++ pk_field ++ "\"]",
            .bigint => |interval| blk: {
                checks = checks ++ readIntegerText(pk_field, pk_field, interval);
                break :blk pk_field;
            },
            .number => |interval| blk: {
                checks = checks ++ readIntegerText(pk_field, pk_field, interval);
                break :blk "Number(" ++ pk_field ++ ")";
            },
            .object => |parts| blk: {
                var literal: []const u8 = "`(";
                for (parts, 0..) |part, j| {
                    const variable = pk_field ++ "_" ++ part.name;
                    switch (part.type) {
                        .bigint, .number => |interval| checks = checks ++ readIntegerText(pk_field ++ "." ++ part.name, variable, interval),
                        else => @compileError("field '" ++ part.name ++ "' of type '" ++ domain ++ "': only integers inside a struct of the pk are read from the query string yet"),
                    }
                    literal = literal ++ (if (j > 0) "," else "") ++ "${" ++ variable ++ "}";
                }
                break :blk literal ++ ")`";
            },
            .boolean => @compileError("field '" ++ pk_field ++ "': a boolean in the pk is not read from the query string yet"),
        };
        object = object ++ (if (i > 0) ", " else "") ++ pk_field ++ ": " ++ value;
    }
    return "// The pk of " ++ entity_name ++ " from its query-string values, each read by its type.\n" ++
        "function pk" ++ pascal(entity_name) ++ "(v: Record<string, string>): { value: any } | { error: string } {\n" ++
        checks ++
        "  return { value: " ++ object ++ " } };\n" ++
        "}\n";
}

/// The lines that read the pk of a request: the query string must be exactly
/// the pk (`readPk`), and each value must fit its type (`pk<Entity>`); else a
/// JSON 400. Leaves the pk, ready for dml.ts, in `key.value`.
fn readKeyText(comptime type_defs: anytype, comptime entity_name: []const u8, comptime entity: anytype) []const u8 {
    return "      const pk = readPk(url.searchParams, [" ++ pkParamsText(type_defs, entity) ++ "]);\n" ++
        "      if (\"error\" in pk) return json(res, 400, { error: pk.error });\n" ++
        "      const key = pk" ++ pascal(entity_name) ++ "(pk.values);\n" ++
        "      if (\"error\" in key) return json(res, 400, { error: key.error });\n";
}

/// The GET route of an entity: without a query string, the list
/// (`selectAll<Entity>`); with one, the row of that pk (`select<Entity>ByPk`),
/// encoded, or a JSON 404.
fn getRoute(comptime type_defs: anytype, comptime entity_name: []const u8, comptime entity: anytype) []const u8 {
    const entity_pascal = pascal(entity_name);
    return "    if (req.method === \"GET\" && url.pathname === \"/api/" ++ entity_name ++ "\") {\n" ++
        "      if (url.search === \"\") {\n" ++
        "        const q = selectAll" ++ entity_pascal ++ "();\n" ++
        "        const { rows } = await pool.query(q.text, q.values);\n" ++
        "        return json(res, 200, rows.map(encode" ++ entity_pascal ++ "));\n" ++
        "      }\n" ++
        readKeyText(type_defs, entity_name, entity) ++
        "      const q = select" ++ entity_pascal ++ "ByPk(key.value);\n" ++
        "      const { rows } = await pool.query(q.text, q.values);\n" ++
        "      if (rows.length === 0) return json(res, 404, { error: \"not found\" });\n" ++
        "      return json(res, 200, encode" ++ entity_pascal ++ "(rows[0]));\n" ++
        "    }\n";
}

/// The delete route of an entity: DELETE /api/<entity>?<pk> -> 204 without a
/// body, or a JSON 404 when no row had that pk; a query string that is not
/// exactly the pk (none included) is a JSON 400, so it never deletes more than
/// one row.
fn deleteRoute(comptime type_defs: anytype, comptime entity_name: []const u8, comptime entity: anytype) []const u8 {
    return "    if (req.method === \"DELETE\" && url.pathname === \"/api/" ++ entity_name ++ "\") {\n" ++
        readKeyText(type_defs, entity_name, entity) ++
        "      const q = delete" ++ pascal(entity_name) ++ "(key.value);\n" ++
        "      const { rowCount } = await pool.query(q.text, q.values);\n" ++
        "      if (rowCount === 0) return json(res, 404, { error: \"not found\" });\n" ++
        "      res.writeHead(204);\n" ++
        "      return res.end();\n" ++
        "    }\n";
}

/// Whether every field of the entity is text: a body of strings is then the
/// row as is (a bigint or a fecha in a body would need the TS -> Postgres
/// translation: not yet).
fn hasTextFields(comptime type_defs: anytype, comptime entity: anytype) bool {
    for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
        const domain = @field(entity.fields, field_name).type;
        if (tsTypeOf(@field(type_defs, domain).Type) != .string) return false;
    }
    return true;
}

/// The create route of an entity whose fields are all text: POST
/// /api/<entity> with the row as a JSON body (`readBody`, told which fields
/// are nullable: nullable and not in the pk) -> 201 without a body; a body
/// that is not a row of the entity is a JSON 400.
fn createRoute(comptime entity_name: []const u8, comptime entity: anytype) []const u8 {
    var fields: []const u8 = "{ ";
    var row: []const u8 = "{ ";
    for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names, 0..) |field_name, i| {
        const nullable = @field(entity.fields, field_name).nullable and !isPkField(entity, field_name);
        const sep = if (i > 0) ", " else "";
        fields = fields ++ sep ++ field_name ++ ": " ++ (if (nullable) "true" else "false");
        row = row ++ sep ++ field_name ++ ": body.values." ++ field_name;
    }
    return "    if (req.method === \"POST\" && url.pathname === \"/api/" ++ entity_name ++ "\") {\n" ++
        "      const body = await readBody(req, " ++ fields ++ " });\n" ++
        "      if (\"error\" in body) return json(res, 400, { error: body.error });\n" ++
        "      const q = insert" ++ pascal(entity_name) ++ "(" ++ row ++ " });\n" ++
        "      await pool.query(q.text, q.values);\n" ++
        "      res.writeHead(201);\n" ++
        "      return res.end();\n" ++
        "    }\n";
}

/// Whether the entity has some field outside the pk: an all-pk entity has
/// nothing to update (dml.ts has no `update<Entity>` for it).
fn hasNonPkFields(comptime entity: anytype) bool {
    for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
        if (!isPkField(entity, field_name)) return true;
    }
    return false;
}

/// The update route of an entity with text fields and some field outside the
/// pk: PUT /api/<entity>?<pk> with the fields outside the pk as a JSON body ->
/// 204 without a body, or a JSON 404 when no row had that pk. The update is
/// the full row (`update<Entity>` of dml.ts): a nullable field the body leaves
/// out is written as null; a pk field in the body is an unknown field.
fn updateRoute(comptime type_defs: anytype, comptime entity_name: []const u8, comptime entity: anytype) []const u8 {
    var fields: []const u8 = "{ ";
    var row: []const u8 = "{ ";
    var first = true;
    for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
        if (isPkField(entity, field_name)) continue;
        const nullable = @field(entity.fields, field_name).nullable;
        const sep = if (first) "" else ", ";
        first = false;
        fields = fields ++ sep ++ field_name ++ ": " ++ (if (nullable) "true" else "false");
        row = row ++ sep ++ field_name ++ ": body.values." ++ field_name;
    }
    return "    if (req.method === \"PUT\" && url.pathname === \"/api/" ++ entity_name ++ "\") {\n" ++
        readKeyText(type_defs, entity_name, entity) ++
        "      const body = await readBody(req, " ++ fields ++ " });\n" ++
        "      if (\"error\" in body) return json(res, 400, { error: body.error });\n" ++
        "      const q = update" ++ pascal(entity_name) ++ "(key.value, " ++ row ++ " });\n" ++
        "      const { rowCount } = await pool.query(q.text, q.values);\n" ++
        "      if (rowCount === 0) return json(res, 404, { error: \"not found\" });\n" ++
        "      res.writeHead(204);\n" ++
        "      return res.end();\n" ++
        "    }\n";
}

fn contains(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// The whole server.ts as a container-level const, so it is comptime-known
/// also where `generateTsServer` is called from a runtime scope (same trick as
/// zigma's `LabelHolder`).
fn ServerHolder(comptime type_defs: anytype, comptime entity_defs: anytype) type {
    return struct {
        const text: []const u8 = blk: {
            @setEvalBranchQuota(200000);
            const entity_names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;
            var imports: []const u8 = "";
            var decoders: []const u8 = "";
            var decoded: []const []const u8 = &.{};
            var functions: []const u8 = "";
            var routes: []const u8 = "";
            for (entity_names, 0..) |entity_name, i| {
                const entity = zigma.completeEntity(@field(entity_defs, entity_name));
                const entity_pascal = pascal(entity_name);
                const text_fields = hasTextFields(type_defs, entity);
                const updatable = text_fields and hasNonPkFields(entity);
                imports = imports ++ (if (i > 0) ", " else "") ++ "selectAll" ++ entity_pascal ++
                    ", select" ++ entity_pascal ++ "ByPk, delete" ++ entity_pascal;
                if (text_fields) imports = imports ++ ", insert" ++ entity_pascal;
                if (updatable) imports = imports ++ ", update" ++ entity_pascal;
                // one decoder per struct domain, the first time it appears
                for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
                    const domain = @field(entity.fields, field_name).type;
                    const t = tsTypeOf(@field(type_defs, domain).Type);
                    if (t == .object and !contains(decoded, domain)) {
                        decoders = decoders ++ decoderFn(domain, t.object) ++ "\n";
                        decoded = decoded ++ &[_][]const u8{domain};
                    }
                }
                functions = functions ++ encoderFn(type_defs, entity_name, entity) ++ "\n" ++
                    pkFn(type_defs, entity_name, entity) ++ "\n";
                routes = routes ++ getRoute(type_defs, entity_name, entity) ++ deleteRoute(type_defs, entity_name, entity);
                if (text_fields) routes = routes ++ createRoute(entity_name, entity);
                if (updatable) routes = routes ++ updateRoute(type_defs, entity_name, entity);
            }
            break :blk header_before_imports ++ imports ++ header_after_imports ++
                decoders ++ functions ++ server_start ++ routes ++ footer;
        };
    };
}

/// The HTTP server of the given entities (`.{ .periodos = aida.periodos }`),
/// over the system's `type_defs`: for every entity a GET route (the list, and
/// one row by its pk) and a DELETE route; a POST route when every field is
/// text, and a PUT route when, besides, some field is outside the pk; in
/// declaration order.
pub fn generateTsServer(comptime type_defs: anytype, comptime entity_defs: anytype) []const u8 {
    return ServerHolder(type_defs, entity_defs).text;
}
