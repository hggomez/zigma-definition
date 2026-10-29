//! Tests for the generation of the frontend, driving `frontend_generator.zig`:
//! plain HTML + JS (no framework, no build step), generated from the SSOT like
//! server.ts. One page per entity, its URL mirroring the API (/docentes shows
//! what GET /api/docentes returns), plus an index of the entities and a fixed
//! common.js the pages share.
//!
//! First step: navigate and list (read only). Each entity page is a table: a
//! column per field, its header the field's label (from the FieldInfo), and a
//! cell per value as the JSON response has it, every number kept as its exact
//! text (a bigint is never rounded through a JS number); null is an empty
//! cell, a struct its fields in order joined with "-" (`fecha` shows as
//! 2026-3-14: a display of its own for dates is pending).
//!
//! The look is an admin panel: every page has the same frame, a header with
//! the system's name (linking the index), a sidebar nav with every entity in
//! declaration order (the page's own marked aria-current="page") and the
//! content in <main>; a fixed common.css the pages link lays it out.

const std = @import("std");
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

test "entityHtml: the frame with its own entity current, and a table with a column per field, its header the field's label, filled from the API" {
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
        \\<table>
        \\<thead>
        \\<tr><th>materia</th><th>denominación</th></tr>
        \\</thead>
        \\<tbody></tbody>
        \\</table>
        \\</main>
        \\<script type="module">
        \\import { list, cell, struct } from "/common.js";
        \\list("materias", [
        \\  (row) => cell(row.materia),
        \\  (row) => cell(row.denominacion),
        \\]);
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

test "entityHtml: a bigint is a cell like any other value, a struct its fields joined with '-'" {
    const page = fe.entityHtml("aida", aida.type_defs, aida.entity_defs, "clases");
    try std.testing.expect(std.mem.indexOf(u8, page,
        \\list("clases", [
        \\  (row) => cell(row.periodo),
        \\  (row) => cell(row.materia),
        \\  (row) => cell(row.orden),
        \\  (row) => struct(row.fecha, ["año", "mes", "día"]),
        \\  (row) => cell(row.tema),
        \\]);
    ) != null);
}

test "common_js: reads the API keeping every number as its exact text" {
    try std.testing.expect(std.mem.indexOf(u8, fe.common_js,
        \\  return JSON.parse(await res.text(), (key, value, context) => (typeof value === "number" ? context.source : value));
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, fe.common_js, "export async function list(entity, columns) {") != null);
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
    // narrow screens: one column, the nav above the content
    try std.testing.expect(has("@media (max-width: 640px) {"));
}
