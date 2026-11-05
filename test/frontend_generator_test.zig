//! Tests of the generation of the frontend (`frontend_generator.zig`):
//! plain HTML + JS (no framework, no build step), generated from the SSOT like
//! server.ts. One page per entity, its URL mirroring the API (/docentes shows
//! what GET /api/docentes returns), plus an index of the entities and a fixed
//! common.js the pages share.
//!
//! The pages navigate, list, show one row, delete it and create one. An entity page
//! mirrors the API: without a query string it is the list, a table with a
//! column per field (its header the field's label, from the FieldInfo), the
//! first cell of each row linking to the row's page; with the query string of
//! a pk (/clases?periodo=…&materia=…&orden=…, a struct one parameter per
//! field) it is that row, its fields as label/value pairs and a Delete button
//! (an on-page confirmation, then back to the list; a generic error when the
//! API refuses), or a not-found message. The list links to /<entity>/new, a
//! form built from a descriptor per field (its kind of input, and whether an
//! empty value is null), which posts the row and goes back to the list. Each value is shown as the JSON response has it, every number
//! kept as its exact text (a bigint is never rounded through a JS number);
//! null is empty, a struct its fields in order joined with "-" (`fecha` shows
//! as 2026-3-14).
//!
//! The look is an admin panel: every page has the same frame, a header with
//! the system's name (linking the index), a sidebar nav with every entity in
//! declaration order (the page's own marked aria-current="page") and the
//! content in <main>; a fixed common.css the pages link lays it out.

const std = @import("std");
const zigma = @import("zigma");
const aida = @import("aida");
const fe = @import("frontend_generator");
const expectEqualStrings = std.testing.expectEqualStrings;

// two entities are enough for the frame: the nav lists them in this order
const two_entities = .{ .periodos = aida.periodos, .materias = aida.materias };

test "indexHtml: the frame (header, nav with a link per entity in declaration order, none current) and the system's name" {
    try expectEqualStrings(
        \\<!doctype html>
        \\<html>
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>aida</title>
        \\<link rel="stylesheet" href="/common.css">
        \\</head>
        \\<body>
        \\<header><a class="home" href="/">aida</a></header>
        \\<nav>
        \\<ul>
        \\<li><a href="/periodos">periodos</a></li>
        \\<li><a href="/materias">materias</a></li>
        \\</ul>
        \\</nav>
        \\<main>
        \\<h1>aida</h1>
        \\</main>
        \\</body>
        \\</html>
        \\
    , fe.indexHtml("aida", two_entities));
}

test "entityHtml: the frame with its own entity current, a table with a column per field (its header the field's label), and the page's script: each field's label and text, and the pk of a row" {
    try expectEqualStrings(
        \\<!doctype html>
        \\<html>
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>materias</title>
        \\<link rel="stylesheet" href="/common.css">
        \\</head>
        \\<body>
        \\<header><a class="home" href="/">aida</a></header>
        \\<nav>
        \\<ul>
        \\<li><a href="/periodos">periodos</a></li>
        \\<li><a href="/materias" aria-current="page">materias</a></li>
        \\</ul>
        \\</nav>
        \\<main>
        \\<h1>materias</h1>
        \\<a class="new" href="/materias/new">New</a>
        \\<table>
        \\<thead>
        \\<tr><th>materia</th><th>denominación</th></tr>
        \\</thead>
        \\<tbody></tbody>
        \\</table>
        \\</main>
        \\<script type="module">
        \\import { entityPage, cell, struct } from "/common.js";
        \\entityPage("materias", [
        \\  ["materia", (row) => cell(row.materia)],
        \\  ["denominación", (row) => cell(row.denominacion)],
        \\], (row) => ({ "materia": row.materia }));
        \\</script>
        \\</body>
        \\</html>
        \\
    , fe.entityHtml("aida", aida.type_defs, two_entities, "materias"));
}

test "entityHtml: a derived label (email_alternativo -> email alternativo)" {
    const page = fe.entityHtml("aida", aida.type_defs, aida.entity_defs, "docentes");
    try std.testing.expect(std.mem.indexOf(u8, page,
        \\<tr><th>docente</th><th>apellido</th><th>nombres</th><th>cargo</th><th>email</th><th>email alternativo</th><th>jefe</th></tr>
    ) != null);
}

test "entityHtml: a bigint is a value like any other, in a cell and in the pk; a struct its fields joined with '-'" {
    const page = fe.entityHtml("aida", aida.type_defs, aida.entity_defs, "clases");
    try std.testing.expect(std.mem.indexOf(u8, page,
        \\entityPage("clases", [
        \\  ["periodo", (row) => cell(row.periodo)],
        \\  ["materia", (row) => cell(row.materia)],
        \\  ["orden", (row) => cell(row.orden)],
        \\  ["fecha", (row) => struct(row.fecha, ["año", "mes", "día"])],
        \\  ["tema", (row) => cell(row.tema)],
        \\], (row) => ({ "periodo": row.periodo, "materia": row.materia, "orden": row.orden }));
    ) != null);
}

test "entityHtml: a struct in the pk is one query-string parameter per field, like the API's" {
    const page = fe.entityHtml("aida", aida.type_defs, aida.entity_defs, "mesas");
    try std.testing.expect(std.mem.indexOf(u8, page,
        \\], (row) => ({ "periodo": row.periodo, "materia": row.materia, "fecha.año": row.fecha["año"], "fecha.mes": row.fecha["mes"], "fecha.día": row.fecha["día"] }));
    ) != null);
}

test "common_js: reads the API keeping every number as its exact text" {
    try std.testing.expect(std.mem.indexOf(u8, fe.common_js,
        \\  return JSON.parse(await res.text(), (key, value, context) => (typeof value === "number" ? context.source : value));
    ) != null);
}

test "common_js: the entity page is the list without a query string, and the row of that pk with one, like the API" {
    const has = struct {
        fn has(text: []const u8) bool {
            return std.mem.indexOf(u8, fe.common_js, text) != null;
        }
    }.has;
    try std.testing.expect(has("export async function entityPage(entity, columns, pk) {"));
    // the row: the same query string, asked to the API
    try std.testing.expect(has("`/api/${entity}${location.search}`"));
    // the list: the first cell of each row links to the row's page
    try std.testing.expect(has("`?${new URLSearchParams(pk(row))}`"));
    // a pk with no row (the API's 404)
    try std.testing.expect(has("No row with that pk."));
}

test "common_js: the row's page deletes the row after an on-page confirmation, then goes back to the list" {
    const has = struct {
        fn has(text: []const u8) bool {
            return std.mem.indexOf(u8, fe.common_js, text) != null;
        }
    }.has;
    // the button and the confirmation, on the page (no native dialog)
    try std.testing.expect(has("\"Delete\""));
    try std.testing.expect(has("\"Delete this row?\""));
    try std.testing.expect(has("\"Yes, delete\""));
    try std.testing.expect(has("\"Cancel\""));
    try std.testing.expect(!has("confirm("));
    // the API's delete, with the same query string
    try std.testing.expect(has("{ method: \"DELETE\" }"));
    // back to the list: the page without its query string
    try std.testing.expect(has("location.assign(location.pathname)"));
    // anything but a 204: a generic error
    try std.testing.expect(has("\"The row could not be deleted.\""));
}

test "newHtml: the frame with its own entity current, an empty form and the page's script: a descriptor per field (a pk field is never nullable)" {
    try expectEqualStrings(
        \\<!doctype html>
        \\<html>
        \\<head>
        \\<meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width, initial-scale=1">
        \\<title>materias</title>
        \\<link rel="stylesheet" href="/common.css">
        \\</head>
        \\<body>
        \\<header><a class="home" href="/">aida</a></header>
        \\<nav>
        \\<ul>
        \\<li><a href="/periodos">periodos</a></li>
        \\<li><a href="/materias" aria-current="page">materias</a></li>
        \\</ul>
        \\</nav>
        \\<main>
        \\<h1>materias</h1>
        \\<form></form>
        \\</main>
        \\<script type="module">
        \\import { createPage } from "/common.js";
        \\createPage("materias", [
        \\  { name: "materia", label: "materia", kind: "text", nullable: false },
        \\  { name: "denominacion", label: "denominación", kind: "text", nullable: false },
        \\]);
        \\</script>
        \\</body>
        \\</html>
        \\
    , fe.newHtml("aida", aida.type_defs, two_entities, "materias"));
}

test "newHtml: an integer (a bigint too) and a struct, one kind per part; a nullable field outside the pk" {
    const page = fe.newHtml("aida", aida.type_defs, aida.entity_defs, "clases");
    try std.testing.expect(std.mem.indexOf(u8, page,
        \\createPage("clases", [
        \\  { name: "periodo", label: "periodo", kind: "text", nullable: false },
        \\  { name: "materia", label: "materia", kind: "text", nullable: false },
        \\  { name: "orden", label: "orden", kind: "integer", nullable: false },
        \\  { name: "fecha", label: "fecha", kind: { "año": "integer", "mes": "integer", "día": "integer" }, nullable: true },
        \\  { name: "tema", label: "tema", kind: "text", nullable: true },
        \\]);
    ) != null);
}

// ad-hoc: no entity of aida has a boolean field. A container-level const, so
// it is comptime-known in the test below.
const ajustes = zigma.defineEntity(.{ .pk = .{"clave"}, .fields = zigma.record(zigma.common_type_defs, .{
    .clave = .{ .type = "text" },
    .activo = .{ .type = "boolean" },
}) });

test "newHtml: a boolean is its own kind" {
    const page = fe.newHtml("prueba", zigma.common_type_defs, .{ .ajustes = ajustes }, "ajustes");
    try std.testing.expect(std.mem.indexOf(u8, page,
        \\  { name: "activo", label: "activo", kind: "boolean", nullable: true },
    ) != null);
}

test "common_js: the new-row page builds its form from the descriptors, posts the row and goes back to the list" {
    const has = struct {
        fn has(text: []const u8) bool {
            return std.mem.indexOf(u8, fe.common_js, text) != null;
        }
    }.has;
    try std.testing.expect(has("export async function createPage(entity, fields) {"));
    // an input per field, a checkbox for a boolean, a fieldset for a struct
    try std.testing.expect(has("input.type = \"checkbox\""));
    try std.testing.expect(has("document.createElement(\"fieldset\")"));
    // the buttons
    try std.testing.expect(has("\"Create\""));
    try std.testing.expect(has("\"Cancel\""));
    // the row as JSON, an integer as an exact JSON number
    try std.testing.expect(has("JSON.rawJSON("));
    try std.testing.expect(has("{ method: \"POST\""));
    // back to the list; anything but a 201, a generic error
    try std.testing.expect(has("location.assign(`/${entity}`)"));
    try std.testing.expect(has("\"The row could not be created.\""));
}

test "common_css: the admin panel, a sidebar grid with the current entity highlighted and empty cells shown as a dash" {
    const has = struct {
        fn has(text: []const u8) bool {
            return std.mem.indexOf(u8, fe.common_css, text) != null;
        }
    }.has;
    // header and nav in the left column, main beside them
    try std.testing.expect(has("grid-template-columns: 210px 1fr;"));
    try std.testing.expect(has("main { grid-column: 2; grid-row: 1 / 3;"));
    try std.testing.expect(has("nav a[aria-current=\"page\"] {"));
    try std.testing.expect(has("td:empty::after { content: \"\\2014\";"));
    // the row's page: its label/value pairs, an empty value (null) a dash too
    try std.testing.expect(has("dd:empty::after { content: \"\\2014\";"));
    // narrow screens: one column, the nav above the content
    try std.testing.expect(has("@media (max-width: 640px) {"));
}
