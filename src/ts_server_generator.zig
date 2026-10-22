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
//! First operation: only the list (GET /api/<entity>), for the entities given.

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
    \\import { createServer, type ServerResponse } from "node:http";
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

/// The route that lists an entity: GET /api/<entity> -> its rows, encoded, as
/// a JSON array, through `selectAll<Entity>` of dml.ts.
fn listRoute(comptime entity_name: []const u8) []const u8 {
    return "    if (req.method === \"GET\" && url.pathname === \"/api/" ++ entity_name ++ "\") {\n" ++
        "      const q = selectAll" ++ pascal(entity_name) ++ "();\n" ++
        "      const { rows } = await pool.query(q.text, q.values);\n" ++
        "      return json(res, 200, rows.map(encode" ++ pascal(entity_name) ++ "));\n" ++
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
            @setEvalBranchQuota(100000);
            const entity_names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;
            var imports: []const u8 = "";
            var decoders: []const u8 = "";
            var decoded: []const []const u8 = &.{};
            var encoders: []const u8 = "";
            var routes: []const u8 = "";
            for (entity_names, 0..) |entity_name, i| {
                const entity = zigma.completeEntity(@field(entity_defs, entity_name));
                imports = imports ++ (if (i > 0) ", " else "") ++ "selectAll" ++ pascal(entity_name);
                // one decoder per struct domain, the first time it appears
                for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
                    const domain = @field(entity.fields, field_name).type;
                    const t = tsTypeOf(@field(type_defs, domain).Type);
                    if (t == .object and !contains(decoded, domain)) {
                        decoders = decoders ++ decoderFn(domain, t.object) ++ "\n";
                        decoded = decoded ++ &[_][]const u8{domain};
                    }
                }
                encoders = encoders ++ encoderFn(type_defs, entity_name, entity) ++ "\n";
                routes = routes ++ listRoute(entity_name);
            }
            break :blk header_before_imports ++ imports ++ header_after_imports ++
                decoders ++ encoders ++ server_start ++ routes ++ footer;
        };
    };
}

/// The HTTP server of the given entities (`.{ .periodos = aida.periodos }`),
/// over the system's `type_defs`: one GET /api/<entity> route per entity, in
/// declaration order.
pub fn generateTsServer(comptime type_defs: anytype, comptime entity_defs: anytype) []const u8 {
    return ServerHolder(type_defs, entity_defs).text;
}
