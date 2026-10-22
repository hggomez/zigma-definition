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

const std = @import("std");
const aida = @import("aida");
const fe = @import("frontend_generator");
const expectEqualStrings = std.testing.expectEqualStrings;

test "indexHtml: the system's name and a link per entity, in declaration order" {
    try expectEqualStrings(
        \\<!doctype html>
        \\<html>
        \\<head>
        \\<meta charset="utf-8">
        \\<title>aida</title>
        \\</head>
        \\<body>
        \\<h1>aida</h1>
        \\<ul>
        \\<li><a href="/periodos">periodos</a></li>
        \\<li><a href="/materias">materias</a></li>
        \\</ul>
        \\</body>
        \\</html>
        \\
    , fe.indexHtml("aida", .{ .periodos = aida.periodos, .materias = aida.materias }));
}

test "entityHtml: a table with a column per field, its header the field's label, filled from the API" {
    try expectEqualStrings(
        \\<!doctype html>
        \\<html>
        \\<head>
        \\<meta charset="utf-8">
        \\<title>materias</title>
        \\</head>
        \\<body>
        \\<p><a href="/">aida</a></p>
        \\<h1>materias</h1>
        \\<table>
        \\<thead>
        \\<tr><th>materia</th><th>denominación</th></tr>
        \\</thead>
        \\<tbody></tbody>
        \\</table>
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
    , fe.entityHtml("aida", aida.type_defs, "materias", aida.materias));
}

test "entityHtml: a derived label (email_alternativo -> email alternativo)" {
    const page = fe.entityHtml("aida", aida.type_defs, "docentes", aida.docentes);
    try std.testing.expect(std.mem.indexOf(u8, page,
        \\<tr><th>docente</th><th>apellido</th><th>nombres</th><th>cargo</th><th>email</th><th>email alternativo</th><th>jefe</th></tr>
    ) != null);
}

test "entityHtml: a bigint is a cell like any other value, a struct its fields joined with '-'" {
    const page = fe.entityHtml("aida", aida.type_defs, "clases", aida.clases);
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
