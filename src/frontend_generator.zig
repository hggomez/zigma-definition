//! Frontend generation: plain HTML + JS (no framework, no build step), from
//! the system's entities, like server.ts. Two pages per entity, their URLs
//! mirroring the API (/<entity> and /<entity>/new), an index of the
//! entities, and a fixed `common_js` the pages share.
//!
//! The pages navigate, list, show one row, delete it and create one.
//! * Like the API, an entity page without a query string is the list
//!   (/docentes shows what GET /api/docentes returns): a table with a column
//!   per field, its header the field's label (from the FieldInfo), the first
//!   cell of each row linking to the row's page, and a New link.
//! * With the query string of a pk (/clases?periodo=…&…, a struct one
//!   parameter per field) it is that row: its fields as label/value pairs and
//!   a Delete button, which asks for confirmation on the page and, confirmed,
//!   deletes the row through the API and goes back to the list (any answer but
//!   a 204 is a generic error); or a not-found message.
//! * /<entity>/new is a form with an input per field (a checkbox for a
//!   boolean, an input per part for a struct): Create posts the row and goes
//!   back to the list (any answer but a 201 is a generic error, the form keeps
//!   what was typed); an empty nullable field (outside the pk) is null.
//!
//! Each value is shown as the JSON response has it, every number kept as its
//! exact text (a bigint is never rounded through a JS number, nor sent
//! through one); null is empty, a struct its fields in order joined with "-".
//!
//! The look is an admin panel: every page has the same frame, a header with
//! the system's name (linking the index), a sidebar nav with every entity in
//! declaration order (the page's own marked aria-current="page") and the
//! content in <main>, laid out by a fixed `common_css` the pages link.

const std = @import("std");
const zigma = @import("zigma");
const zig_type_map_ts = @import("zig_type_map_ts");
const tsTypeOf = zig_type_map_ts.tsTypeOf;

/// The code every page shares: reading the API, drawing the list of an
/// entity and the page of one of its rows, deleting it, and the form that
/// creates one.
pub const common_js =
    \\// Shared code of the generated pages: reading the API, drawing the list of
    \\// an entity and the page of one of its rows.
    \\
    \\// The body of a JSON response, every number kept as its exact text (a JS
    \\// number would round a bigint): the pages only show the values.
    \\async function readJson(res) {
    \\  return JSON.parse(await res.text(), (key, value, context) => (typeof value === "number" ? context.source : value));
    \\}
    \\
    \\// A JSON response that must be a success.
    \\export async function getJson(path) {
    \\  const res = await fetch(path);
    \\  if (!res.ok) throw new Error(`${path}: ${res.status}`);
    \\  return readJson(res);
    \\}
    \\
    \\// The text of a value: null is empty.
    \\export function cell(value) {
    \\  return value === null ? "" : String(value);
    \\}
    \\
    \\// The text of a struct: its fields in order, joined with "-"; null is empty.
    \\export function struct(value, keys) {
    \\  return value === null ? "" : keys.map((key) => value[key]).join("-");
    \\}
    \\
    \\// The page of an entity, like the API: without a query string, the list of
    \\// its rows; with the query string of a pk, the row of that pk. `columns` has
    \\// a [label, text of the value] per field; `pk` gives the query-string
    \\// parameters of a row's pk.
    \\export async function entityPage(entity, columns, pk) {
    \\  if (location.search === "") return list(entity, columns, pk);
    \\  return show(entity, columns);
    \\}
    \\
    \\// Fills the table with the rows, a cell per column; the first cell of each
    \\// row links to the row's page.
    \\async function list(entity, columns, pk) {
    \\  const rows = await getJson(`/api/${entity}`);
    \\  const tbody = document.querySelector("tbody");
    \\  for (const row of rows) {
    \\    const tr = document.createElement("tr");
    \\    columns.forEach(([, text], i) => {
    \\      const td = document.createElement("td");
    \\      if (i === 0) {
    \\        const a = document.createElement("a");
    \\        a.href = `?${new URLSearchParams(pk(row))}`;
    \\        a.textContent = text(row);
    \\        td.append(a);
    \\      } else {
    \\        td.textContent = text(row);
    \\      }
    \\      tr.append(td);
    \\    });
    \\    tbody.append(tr);
    \\  }
    \\}
    \\
    \\// Replaces the table with the row of the page's query string, its fields
    \\// as label/value pairs, or with a message when no row has that pk.
    \\async function show(entity, columns) {
    \\  const table = document.querySelector("table");
    \\  const res = await fetch(`/api/${entity}${location.search}`);
    \\  if (res.status === 404) {
    \\    const p = document.createElement("p");
    \\    p.textContent = "No row with that pk.";
    \\    table.replaceWith(p);
    \\    return;
    \\  }
    \\  if (!res.ok) throw new Error(`/api/${entity}${location.search}: ${res.status}`);
    \\  const row = await readJson(res);
    \\  const dl = document.createElement("dl");
    \\  for (const [label, text] of columns) {
    \\    const dt = document.createElement("dt");
    \\    dt.textContent = label;
    \\    const dd = document.createElement("dd");
    \\    dd.textContent = text(row);
    \\    dl.append(dt, dd);
    \\  }
    \\  table.replaceWith(dl);
    \\  document.querySelector("a.new").remove();
    \\  dl.after(deleteControls(entity));
    \\}
    \\
    \\// A button that does not submit anything.
    \\function button(text, className) {
    \\  const b = document.createElement("button");
    \\  b.type = "button";
    \\  b.textContent = text;
    \\  if (className) b.className = className;
    \\  return b;
    \\}
    \\
    \\// The delete of the page's row: a button that asks for confirmation on the
    \\// page; confirmed, the API's delete with the same query string, then back
    \\// to the list (the page without its query string). Any answer but a 204
    \\// is a generic error, and the row stays.
    \\function deleteControls(entity) {
    \\  const box = document.createElement("div");
    \\  box.className = "actions";
    \\  const remove = button("Delete", "danger");
    \\  const question = document.createElement("span");
    \\  question.textContent = "Delete this row?";
    \\  const yes = button("Yes, delete", "danger");
    \\  const cancel = button("Cancel");
    \\  const error = document.createElement("p");
    \\  error.className = "error";
    \\  const asking = (on) => {
    \\    if (on) remove.replaceWith(question, yes, cancel);
    \\    else if (!remove.isConnected) {
    \\      question.replaceWith(remove);
    \\      yes.remove();
    \\      cancel.remove();
    \\    }
    \\  };
    \\  remove.addEventListener("click", () => {
    \\    error.textContent = "";
    \\    asking(true);
    \\  });
    \\  cancel.addEventListener("click", () => asking(false));
    \\  yes.addEventListener("click", async () => {
    \\    let status = 0;
    \\    try {
    \\      status = (await fetch(`/api/${entity}${location.search}`, { method: "DELETE" })).status;
    \\    } catch {}
    \\    if (status === 204) return location.assign(location.pathname);
    \\    asking(false);
    \\    error.textContent = "The row could not be deleted.";
    \\  });
    \\  box.append(remove, error);
    \\  return box;
    \\}
    \\
    \\// The page that creates a row: a form with an input per field. Create posts
    \\// the row as JSON and goes back to the list; any answer but a 201 is a
    \\// generic error, and the form keeps what was typed. Cancel goes back to the
    \\// list. `fields` has a { name, label, kind, nullable } per field.
    \\export async function createPage(entity, fields) {
    \\  const form = document.querySelector("form");
    \\  const readers = fields.map((field) => fieldInput(form, field));
    \\  const create = button("Create", "primary");
    \\  create.type = "submit";
    \\  const cancel = document.createElement("a");
    \\  cancel.className = "cancel";
    \\  cancel.href = `/${entity}`;
    \\  cancel.textContent = "Cancel";
    \\  const error = document.createElement("p");
    \\  error.className = "error";
    \\  const actions = document.createElement("div");
    \\  actions.className = "actions";
    \\  actions.append(create, cancel, error);
    \\  form.append(actions);
    \\  form.addEventListener("submit", async (event) => {
    \\    event.preventDefault();
    \\    error.textContent = "";
    \\    let status = 0;
    \\    try {
    \\      const row = {};
    \\      fields.forEach((field, i) => {
    \\        row[field.name] = readers[i]();
    \\      });
    \\      const body = JSON.stringify(row);
    \\      status = (await fetch(`/api/${entity}`, { method: "POST", headers: { "content-type": "application/json" }, body })).status;
    \\    } catch {}
    \\    if (status === 201) return location.assign(`/${entity}`);
    \\    error.textContent = "The row could not be created.";
    \\  });
    \\}
    \\
    \\// The input of a field, appended to `parent`, and the reader of its value
    \\// for the JSON: a struct is a fieldset with an input per part; an empty
    \\// value (a struct with every part empty) is null when the field is nullable.
    \\function fieldInput(parent, field) {
    \\  if (typeof field.kind === "object") {
    \\    const fieldset = document.createElement("fieldset");
    \\    const legend = document.createElement("legend");
    \\    legend.textContent = field.label;
    \\    fieldset.append(legend);
    \\    const parts = Object.entries(field.kind).map(([name, kind]) => [name, labeledInput(fieldset, name, kind)]);
    \\    parent.append(fieldset);
    \\    return () => {
    \\      if (field.nullable && parts.every(([, part]) => part.empty())) return null;
    \\      return Object.fromEntries(parts.map(([name, part]) => [name, part.value()]));
    \\    };
    \\  }
    \\  const one = labeledInput(parent, field.label, field.kind);
    \\  return () => (field.nullable && one.empty() ? null : one.value());
    \\}
    \\
    \\// A labeled input of a value of `kind` ("text", "integer" or "boolean", a
    \\// checkbox): whether it is empty, and its value for the JSON, an integer as
    \\// an exact JSON number (JSON.rawJSON throws when the text is not one).
    \\function labeledInput(parent, text, kind) {
    \\  const label = document.createElement("label");
    \\  label.textContent = text;
    \\  const input = document.createElement("input");
    \\  if (kind === "boolean") input.type = "checkbox";
    \\  label.append(input);
    \\  parent.append(label);
    \\  return {
    \\    empty: () => kind !== "boolean" && input.value === "",
    \\    value: () => (kind === "boolean" ? input.checked : kind === "integer" ? JSON.rawJSON(input.value.trim()) : input.value),
    \\  };
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
    \\td a { color: #1d4ed8; font-weight: 600; text-decoration: none; }
    \\td a:hover { text-decoration: underline; }
    \\dl { display: grid; grid-template-columns: max-content 1fr; gap: 0; margin: 0; background: #fff; border-radius: 12px; box-shadow: 0 1px 2px rgba(15, 23, 42, .06), 0 4px 16px rgba(15, 23, 42, .06); overflow: hidden; }
    \\dt { padding: 12px 16px; font-size: 11.5px; text-transform: uppercase; letter-spacing: .06em; color: #64748b; border-bottom: 1px solid #f1f5f9; }
    \\dd { margin: 0; padding: 12px 16px; border-bottom: 1px solid #f1f5f9; }
    \\dd:empty::after { content: "\2014"; color: #cbd5e1; }
    \\.actions { display: flex; flex-wrap: wrap; align-items: center; gap: 10px; margin-top: 18px; }
    \\button { font: inherit; padding: 7px 16px; border-radius: 7px; border: 1px solid #cbd5e1; background: #fff; color: #1e293b; cursor: pointer; }
    \\button:hover { background: #f8fafc; }
    \\button.danger { border-color: #dc2626; background: #dc2626; color: #fff; }
    \\button.danger:hover { background: #b91c1c; }
    \\.error { flex-basis: 100%; margin: 0; color: #b91c1c; }
    \\.error:empty { display: none; }
    \\button.primary { border-color: #1e40af; background: #1e40af; color: #fff; }
    \\button.primary:hover { background: #1e3a8a; }
    \\a.new { display: inline-block; margin-bottom: 14px; padding: 7px 16px; border-radius: 7px; background: #1e40af; color: #fff; text-decoration: none; }
    \\a.new:hover { background: #1e3a8a; }
    \\a.cancel { color: #475569; }
    \\form { display: grid; gap: 14px; max-width: 560px; padding: 20px; background: #fff; border-radius: 12px; box-shadow: 0 1px 2px rgba(15, 23, 42, .06), 0 4px 16px rgba(15, 23, 42, .06); }
    \\label { display: grid; gap: 4px; font-size: 11.5px; text-transform: uppercase; letter-spacing: .06em; color: #64748b; }
    \\input { font: inherit; font-size: 14px; text-transform: none; letter-spacing: normal; color: #1e293b; padding: 7px 10px; border: 1px solid #cbd5e1; border-radius: 7px; }
    \\input[type="checkbox"] { justify-self: start; }
    \\fieldset { display: grid; grid-template-columns: repeat(auto-fit, minmax(90px, 1fr)); gap: 10px; margin: 0; padding: 12px; border: 1px solid #e2e8f0; border-radius: 9px; }
    \\legend { padding: 0 6px; font-size: 11.5px; text-transform: uppercase; letter-spacing: .06em; color: #64748b; }
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

/// The JS that gives the query-string parameters of a row's pk, in pk order,
/// like the API reads them: a field's value by its name, a struct one
/// parameter per field (`"fecha.año": row.fecha["año"]`).
fn pkParams(comptime type_defs: anytype, comptime entity: anytype) []const u8 {
    var params: []const u8 = "";
    for (entity.pk) |pk_field| {
        const field = @field(entity.fields, pk_field);
        switch (tsTypeOf(@field(type_defs, field.type).Type)) {
            .object => |parts| for (parts) |part| {
                params = params ++ (if (params.len > 0) ", " else "") ++
                    "\"" ++ pk_field ++ "." ++ part.name ++ "\": row." ++ pk_field ++ "[\"" ++ part.name ++ "\"]";
            },
            else => params = params ++ (if (params.len > 0) ", " else "") ++ "\"" ++ pk_field ++ "\": row." ++ pk_field,
        }
    }
    return "(row) => ({ " ++ params ++ " })";
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
                columns = columns ++ "  [\"" ++ field.label ++ "\", " ++ columnText(field_name, tsTypeOf(@field(type_defs, field.type).Type)) ++ "],\n";
            }
            break :blk page(system_name, entity_defs, entity_name, entity_name, "<h1>" ++ entity_name ++ "</h1>\n" ++
                "<a class=\"new\" href=\"/" ++ entity_name ++ "/new\">New</a>\n" ++
                "<table>\n" ++
                "<thead>\n" ++
                "<tr>" ++ headers ++ "</tr>\n" ++
                "</thead>\n" ++
                "<tbody></tbody>\n" ++
                "</table>\n", "<script type=\"module\">\n" ++
                "import { entityPage, cell, struct } from \"/common.js\";\n" ++
                "entityPage(\"" ++ entity_name ++ "\", [\n" ++ columns ++ "], " ++ pkParams(type_defs, entity) ++ ");\n" ++
                "</script>\n");
        };
    };
}

/// <entity>.html: the frame (its own entity current in the nav), a table with
/// a column per field (its header the field's label), and the script that
/// gives common.js's `entityPage` each field's label and text and the pk of a
/// row: the list fills the table from GET /api/<entity>, the row's page
/// replaces it. `entity_defs` is the whole system's, for the nav; the page is
/// the one of `entity_name`.
pub fn entityHtml(comptime system_name: []const u8, comptime type_defs: anytype, comptime entity_defs: anytype, comptime entity_name: []const u8) []const u8 {
    return EntityHolder(system_name, type_defs, entity_defs, entity_name).text;
}

/// The kind of a field's input on the new-row page, as JS: "text", "integer"
/// (any integer, a bigint too: its text goes as an exact JSON number),
/// "boolean", or for a struct an object with the kind of each part.
fn kindText(comptime t: zig_type_map_ts.TsType) []const u8 {
    return switch (t) {
        .string => "\"text\"",
        .number, .bigint => "\"integer\"",
        .boolean => "\"boolean\"",
        .object => |parts| blk: {
            var text: []const u8 = "{ ";
            for (parts, 0..) |part, i| text = text ++ (if (i > 0) ", " else "") ++ "\"" ++ part.name ++ "\": " ++ kindText(part.type);
            break :blk text ++ " }";
        },
    };
}

fn NewHolder(comptime system_name: []const u8, comptime type_defs: anytype, comptime entity_defs: anytype, comptime entity_name: []const u8) type {
    return struct {
        const text: []const u8 = blk: {
            @setEvalBranchQuota(100000);
            const entity = zigma.completeEntity(@field(entity_defs, entity_name));
            var fields: []const u8 = "";
            for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
                const field = @field(entity.fields, field_name);
                const in_pk = for (entity.pk) |pk_field| {
                    if (std.mem.eql(u8, pk_field, field_name)) break true;
                } else false;
                fields = fields ++ "  { name: \"" ++ field_name ++ "\", label: \"" ++ field.label ++
                    "\", kind: " ++ kindText(tsTypeOf(@field(type_defs, field.type).Type)) ++
                    ", nullable: " ++ (if (field.nullable and !in_pk) "true" else "false") ++ " },\n";
            }
            break :blk page(system_name, entity_defs, entity_name, entity_name, "<h1>" ++ entity_name ++ "</h1>\n" ++
                "<form></form>\n", "<script type=\"module\">\n" ++
                "import { createPage } from \"/common.js\";\n" ++
                "createPage(\"" ++ entity_name ++ "\", [\n" ++ fields ++ "]);\n" ++
                "</script>\n");
        };
    };
}

/// <entity>/new.html: the frame (its own entity current in the nav), an empty
/// form and the script that gives common.js's `createPage` a descriptor per
/// field: its name, label, kind of input and whether an empty value is null
/// (a nullable field outside the pk).
pub fn newHtml(comptime system_name: []const u8, comptime type_defs: anytype, comptime entity_defs: anytype, comptime entity_name: []const u8) []const u8 {
    return NewHolder(system_name, type_defs, entity_defs, entity_name).text;
}
