//! server.ts generation: the HTTP layer of the TS backend, from the system's
//! entities. Plain Node (`node:http`, no framework) and `pg`; one explicit
//! route per entity and operation, each calling the builder of dml.ts and
//! running it on the pool. The API lives under /api/<entity>; every response
//! is JSON: a list is a bare array, an error is `{ "error": ... }` (404 for
//! anything without a route, 500 for an exception, which is logged).
//!
//! First step: only the list (GET /api/<entity>), for the entities given.

const std = @import("std");
const ts_backend_generator = @import("ts_backend_generator");
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

/// The route that lists an entity: GET /api/<entity> -> its rows as a JSON
/// array, through `selectAll<Entity>` of dml.ts.
fn listRoute(comptime entity_name: []const u8, comptime builder: []const u8) []const u8 {
    return "    if (req.method === \"GET\" && url.pathname === \"/api/" ++ entity_name ++ "\") {\n" ++
        "      const q = " ++ builder ++ "();\n" ++
        "      const { rows } = await pool.query(q.text, q.values);\n" ++
        "      return json(res, 200, rows);\n" ++
        "    }\n";
}

/// The whole server.ts as a container-level const, so it is comptime-known
/// also where `generateTsServer` is called from a runtime scope (same trick as
/// zigma's `LabelHolder`).
fn ServerHolder(comptime entity_defs: anytype) type {
    return struct {
        const text: []const u8 = blk: {
            const entity_names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;
            var imports: []const u8 = "";
            var routes: []const u8 = "";
            for (entity_names, 0..) |entity_name, i| {
                const pascal: []const u8 = &PascalHolder(entity_name).value;
                const builder = "selectAll" ++ pascal;
                imports = imports ++ (if (i > 0) ", " else "") ++ builder;
                routes = routes ++ listRoute(entity_name, builder);
            }
            break :blk header_before_imports ++ imports ++ header_after_imports ++ routes ++ footer;
        };
    };
}

/// The HTTP server of the given entities (`.{ .periodos = aida.periodos }`):
/// one GET /api/<entity> route per entity, in declaration order.
pub fn generateTsServer(comptime entity_defs: anytype) []const u8 {
    return ServerHolder(entity_defs).text;
}
