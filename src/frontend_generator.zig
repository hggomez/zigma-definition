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

const page_start =
    \\<!doctype html>
    \\<html>
    \\<head>
    \\<meta charset="utf-8">
    \\
;

const page_end =
    \\</body>
    \\</html>
    \\
;

/// The index as a container-level const, so it is comptime-known also where
/// `indexHtml` is called from a runtime scope (same trick as zigma's
/// `LabelHolder`).
fn IndexHolder(comptime system_name: []const u8, comptime entity_defs: anytype) type {
    return struct {
        const text: []const u8 = blk: {
            var links: []const u8 = "";
            for (@typeInfo(@TypeOf(entity_defs)).@"struct".field_names) |entity_name| {
                links = links ++ "<li><a href=\"/" ++ entity_name ++ "\">" ++ entity_name ++ "</a></li>\n";
            }
            break :blk page_start ++
                "<title>" ++ system_name ++ "</title>\n" ++
                "</head>\n" ++
                "<body>\n" ++
                "<h1>" ++ system_name ++ "</h1>\n" ++
                "<ul>\n" ++ links ++ "</ul>\n" ++
                page_end;
        };
    };
}

/// index.html: the system's name and a link to each entity's page, in
/// declaration order.
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

fn EntityHolder(comptime system_name: []const u8, comptime type_defs: anytype, comptime entity_name: []const u8, comptime entity_def: anytype) type {
    return struct {
        const text: []const u8 = blk: {
            @setEvalBranchQuota(100000);
            const entity = zigma.completeEntity(entity_def);
            var headers: []const u8 = "";
            var columns: []const u8 = "";
            for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
                const field = @field(entity.fields, field_name);
                headers = headers ++ "<th>" ++ field.label ++ "</th>";
                columns = columns ++ "  " ++ columnText(field_name, tsTypeOf(@field(type_defs, field.type).Type)) ++ ",\n";
            }
            break :blk page_start ++
                "<title>" ++ entity_name ++ "</title>\n" ++
                "</head>\n" ++
                "<body>\n" ++
                "<p><a href=\"/\">" ++ system_name ++ "</a></p>\n" ++
                "<h1>" ++ entity_name ++ "</h1>\n" ++
                "<table>\n" ++
                "<thead>\n" ++
                "<tr>" ++ headers ++ "</tr>\n" ++
                "</thead>\n" ++
                "<tbody></tbody>\n" ++
                "</table>\n" ++
                "<script type=\"module\">\n" ++
                "import { list, cell, struct } from \"/common.js\";\n" ++
                "list(\"" ++ entity_name ++ "\", [\n" ++ columns ++ "]);\n" ++
                "</script>\n" ++
                page_end;
        };
    };
}

/// <entity>.html: the entity's rows as a table, a column per field (its
/// header the field's label), filled from GET /api/<entity> by common.js.
pub fn entityHtml(comptime system_name: []const u8, comptime type_defs: anytype, comptime entity_name: []const u8, comptime entity_def: anytype) []const u8 {
    return EntityHolder(system_name, type_defs, entity_name, entity_def).text;
}
