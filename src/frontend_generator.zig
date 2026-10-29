//! Frontend generation: plain HTML + JS (no framework, no build step), from
//! the system's entities, like server.ts. One page per entity, its URL
//! mirroring the API (/docentes shows what GET /api/docentes returns), an
//! index of the entities, and a fixed `common_js` the pages share.
//!
//! First step: navigate and list (read only). Each entity page is a table: a
//! column per field, its header the field's label (from the FieldInfo), and a
//! cell per value as the JSON response has it, every number kept as its exact
//! text (a bigint is never rounded through a JS number); null is an empty
//! cell, a struct its fields in order joined with "-" (a display of its own
//! for dates is pending).
//!
//! The look is an admin panel: every page has the same frame, a header with
//! the system's name (linking the index), a sidebar nav with every entity in
//! declaration order (the page's own marked aria-current="page") and the
//! content in <main>, laid out by a fixed `common_css` the pages link.

const std = @import("std");
const zigma = @import("zigma");
const zig_type_map_ts = @import("zig_type_map_ts");
const tsTypeOf = zig_type_map_ts.tsTypeOf;

/// The code every page shares: reading the API and drawing a table.
pub const common_js =
    \\// Shared code of the generated pages: reading the API and drawing a table.
    \\
    \\// A JSON response, every number kept as its exact text (a JS number would
    \\// round a bigint): the pages only show the values.
    \\export async function getJson(path) {
    \\  const res = await fetch(path);
    \\  if (!res.ok) throw new Error(`${path}: ${res.status}`);
    \\  return JSON.parse(await res.text(), (key, value, context) => (typeof value === "number" ? context.source : value));
    \\}
    \\
    \\// The text of a value in a cell: null is an empty cell.
    \\export function cell(value) {
    \\  return value === null ? "" : String(value);
    \\}
    \\
    \\// A struct in a cell: its fields in order, joined with "-"; null is empty.
    \\export function struct(value, keys) {
    \\  return value === null ? "" : keys.map((key) => value[key]).join("-");
    \\}
    \\
    \\// Fills the table of the page with the rows of the entity, a cell per column.
    \\export async function list(entity, columns) {
    \\  const rows = await getJson(`/api/${entity}`);
    \\  const tbody = document.querySelector("tbody");
    \\  for (const row of rows) {
    \\    const tr = document.createElement("tr");
    \\    for (const column of columns) {
    \\      const td = document.createElement("td");
    \\      td.textContent = column(row);
    \\      tr.append(td);
    \\    }
    \\    tbody.append(tr);
    \\  }
    \\}
    \\
;

/// The look every page shares: an admin panel. The header and the nav are the
/// left column (dark), main the right one; on a narrow screen, one column with
/// the nav's links in a row above the content. An empty cell (null) shows a
/// dash, by CSS: the cell's text stays empty.
pub const common_css =
    \\/* Shared look of the generated pages: an admin panel. */
    \\body { margin: 0; font: 14px/1.5 "Inter", system-ui, -apple-system, "Segoe UI", sans-serif; color: #1e293b; background: #f1f5f9; display: grid; grid-template-columns: 210px 1fr; grid-template-rows: auto 1fr; min-height: 100vh; }
    \\header { grid-column: 1; grid-row: 1; background: #0f172a; padding: 18px 20px; }
    \\.home { color: #fff; font-weight: 700; font-size: 18px; text-decoration: none; }
    \\.home::before { content: ""; display: inline-block; width: 10px; height: 10px; border-radius: 3px; background: #38bdf8; margin-right: 9px; }
    \\nav { grid-column: 1; grid-row: 2; background: #0f172a; padding: 6px 10px 20px; }
    \\nav ul { list-style: none; margin: 0; padding: 0; }
    \\nav a { display: block; padding: 7px 12px; border-radius: 7px; color: #94a3b8; text-decoration: none; }
    \\nav a:hover { background: #1e293b; color: #e2e8f0; }
    \\nav a[aria-current="page"] { background: #1e40af; color: #fff; }
    \\main { grid-column: 2; grid-row: 1 / 3; padding: 28px 32px; min-width: 0; }
    \\h1 { margin: 0 0 18px; font-size: 22px; text-transform: capitalize; }
    \\table { border-collapse: separate; border-spacing: 0; width: 100%; background: #fff; border-radius: 12px; box-shadow: 0 1px 2px rgba(15, 23, 42, .06), 0 4px 16px rgba(15, 23, 42, .06); overflow: hidden; }
    \\th { text-align: left; padding: 12px 16px; font-size: 11.5px; text-transform: uppercase; letter-spacing: .06em; color: #64748b; border-bottom: 1px solid #e2e8f0; }
    \\td { padding: 13px 16px; border-bottom: 1px solid #f1f5f9; }
    \\tbody tr:nth-child(even) td { background: #f8fafc; }
    \\tbody tr:hover td { background: #eff6ff; }
    \\td:empty::after { content: "\2014"; color: #cbd5e1; }
    \\@media (max-width: 640px) {
    \\  body { grid-template-columns: 1fr; grid-template-rows: auto auto 1fr; }
    \\  header, nav, main { grid-column: 1; grid-row: auto; }
    \\  nav ul { display: flex; flex-wrap: wrap; gap: 4px; }
    \\  main { padding: 20px 16px; overflow-x: auto; }
    \\}
    \\
;

/// A page: the head (its title, the shared stylesheet) and the frame every
/// page shares, a header with the system's name linking the index and a nav
/// with every entity in declaration order (`current` marked, when the page is
/// one of them), around `content`, which goes inside <main>; `after` is what
/// follows main (the page's script).
fn page(
    comptime system_name: []const u8,
    comptime entity_defs: anytype,
    comptime current: ?[]const u8,
    comptime title: []const u8,
    comptime content: []const u8,
    comptime after: []const u8,
) []const u8 {
    var links: []const u8 = "";
    for (@typeInfo(@TypeOf(entity_defs)).@"struct".field_names) |entity_name| {
        const is_current = if (current) |c| std.mem.eql(u8, c, entity_name) else false;
        links = links ++ "<li><a href=\"/" ++ entity_name ++ "\"" ++
            (if (is_current) " aria-current=\"page\"" else "") ++ ">" ++ entity_name ++ "</a></li>\n";
    }
    return "<!doctype html>\n" ++
        "<html>\n" ++
        "<head>\n" ++
        "<meta charset=\"utf-8\">\n" ++
        "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n" ++
        "<title>" ++ title ++ "</title>\n" ++
        "<link rel=\"stylesheet\" href=\"/common.css\">\n" ++
        "</head>\n" ++
        "<body>\n" ++
        "<header><a class=\"home\" href=\"/\">" ++ system_name ++ "</a></header>\n" ++
        "<nav>\n" ++
        "<ul>\n" ++ links ++ "</ul>\n" ++
        "</nav>\n" ++
        "<main>\n" ++ content ++ "</main>\n" ++
        after ++
        "</body>\n" ++
        "</html>\n";
}

/// The index as a container-level const, so it is comptime-known also where
/// `indexHtml` is called from a runtime scope (same trick as zigma's
/// `LabelHolder`).
fn IndexHolder(comptime system_name: []const u8, comptime entity_defs: anytype) type {
    return struct {
        const text: []const u8 = page(system_name, entity_defs, null, system_name, "<h1>" ++ system_name ++ "</h1>\n", "");
    };
}

/// index.html: the frame (a link to each entity's page in the nav, in
/// declaration order, none current) and the system's name.
pub fn indexHtml(comptime system_name: []const u8, comptime entity_defs: anytype) []const u8 {
    return IndexHolder(system_name, entity_defs).text;
}

/// The JS that turns a row's value into its cell: a struct its fields joined
/// with "-", anything else as is (numbers already as their exact text).
fn columnText(comptime field_name: []const u8, comptime t: zig_type_map_ts.TsType) []const u8 {
    return switch (t) {
        .object => |parts| blk: {
            var keys: []const u8 = "";
            for (parts, 0..) |part, i| keys = keys ++ (if (i > 0) ", " else "") ++ "\"" ++ part.name ++ "\"";
            break :blk "(row) => struct(row." ++ field_name ++ ", [" ++ keys ++ "])";
        },
        else => "(row) => cell(row." ++ field_name ++ ")",
    };
}

fn EntityHolder(comptime system_name: []const u8, comptime type_defs: anytype, comptime entity_defs: anytype, comptime entity_name: []const u8) type {
    return struct {
        const text: []const u8 = blk: {
            @setEvalBranchQuota(100000);
            const entity = zigma.completeEntity(@field(entity_defs, entity_name));
            var headers: []const u8 = "";
            var columns: []const u8 = "";
            for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
                const field = @field(entity.fields, field_name);
                headers = headers ++ "<th>" ++ field.label ++ "</th>";
                columns = columns ++ "  " ++ columnText(field_name, tsTypeOf(@field(type_defs, field.type).Type)) ++ ",\n";
            }
            break :blk page(system_name, entity_defs, entity_name, entity_name, "<h1>" ++ entity_name ++ "</h1>\n" ++
                "<table>\n" ++
                "<thead>\n" ++
                "<tr>" ++ headers ++ "</tr>\n" ++
                "</thead>\n" ++
                "<tbody></tbody>\n" ++
                "</table>\n", "<script type=\"module\">\n" ++
                "import { list, cell, struct } from \"/common.js\";\n" ++
                "list(\"" ++ entity_name ++ "\", [\n" ++ columns ++ "]);\n" ++
                "</script>\n");
        };
    };
}

/// <entity>.html: the frame (its own entity current in the nav) and the
/// entity's rows as a table, a column per field (its header the field's
/// label), filled from GET /api/<entity> by common.js. `entity_defs` is the
/// whole system's, for the nav; the page is the one of `entity_name`.
pub fn entityHtml(comptime system_name: []const u8, comptime type_defs: anytype, comptime entity_defs: anytype, comptime entity_name: []const u8) []const u8 {
    return EntityHolder(system_name, type_defs, entity_defs, entity_name).text;
}
