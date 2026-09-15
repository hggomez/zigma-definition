//! JSON writer for record instances: field names and values come from the
//! instance, not from a handwritten format string.

const std = @import("std");
const zigma = @import("zigma");
const aida = @import("aida");
const zigma_json = @import("zigma_json");
const tiny = @import("tiny_system.zig");

const expectEqualStrings = std.testing.expectEqualStrings;

test "stringifies a materia row from its fields" {
    const MateriaRow = zigma.RecordInstanceType(aida.type_defs, aida.materia);
    var buf: [256]u8 = undefined;

    const algo_i: MateriaRow = .{
        .materia = "AlgoI",
        .denominacion = "Algoritmos y Programacion I",
    };
    try expectEqualStrings(
        "{\"materia\":\"AlgoI\",\"denominacion\":\"Algoritmos y Programacion I\"}",
        try zigma_json.stringifyRecord(algo_i, &buf),
    );

    const algo_ii: MateriaRow = .{
        .materia = "AlgoII",
        .denominacion = "Algoritmos y Programacion II",
    };
    try expectEqualStrings(
        "{\"materia\":\"AlgoII\",\"denominacion\":\"Algoritmos y Programacion II\"}",
        try zigma_json.stringifyRecord(algo_ii, &buf),
    );
}

test "stringifies a list of materia rows as a JSON array" {
    const MateriaRow = zigma.RecordInstanceType(aida.type_defs, aida.materia);
    var buf: [512]u8 = undefined;

    const rows = [_]MateriaRow{
        .{ .materia = "AlgoI", .denominacion = "Algoritmos y Programacion I" },
        .{ .materia = "AlgoII", .denominacion = "Algoritmos y Programacion II" },
        .{ .materia = "BD", .denominacion = "Bases de Datos" },
    };
    try expectEqualStrings(
        "[{\"materia\":\"AlgoI\",\"denominacion\":\"Algoritmos y Programacion I\"},{\"materia\":\"AlgoII\",\"denominacion\":\"Algoritmos y Programacion II\"},{\"materia\":\"BD\",\"denominacion\":\"Bases de Datos\"}]",
        try zigma_json.stringifyRecords(&rows, &buf),
    );
}

test "stringifies a record schema from completeRecord" {
    const materia_info = zigma.completeRecord(aida.materia);
    var buf: [256]u8 = undefined;
    try expectEqualStrings(
        "[{\"name\":\"materia\",\"label\":\"materia\"},{\"name\":\"denominacion\",\"label\":\"denominación\"}]",
        try zigma_json.stringifyRecordSchema(materia_info, &buf),
    );
}

test "stringifies an entity schema from completeEntity" {
    var buf: [512]u8 = undefined;
    try expectEqualStrings(
        "{\"name\":\"materias\",\"pk\":[\"materia\"],\"uks\":{\"denominacion\":[\"denominacion\"]},\"fks\":{},\"fields\":[{\"name\":\"materia\",\"label\":\"materia\",\"type\":\"text\",\"is_name\":false,\"storage\":\"text\"},{\"name\":\"denominacion\",\"label\":\"denominación\",\"type\":\"text\",\"is_name\":true,\"storage\":\"text\"}]}",
        try zigma_json.stringifyEntitySchema(aida.type_defs, "materias", aida.materias, &buf),
    );
}

test "stringifies entity fks as source-to-target maps" {
    var buf: [2048]u8 = undefined;
    const json = try zigma_json.stringifyEntitySchema(aida.type_defs, "docentes", aida.docentes, &buf);
    try expectEqualStrings(
        "{\"name\":\"docentes\",\"pk\":[\"docente\"],\"uks\":{},\"fks\":{\"jefe\":{\"entity\":\"docentes\",\"fields\":{\"jefe\":\"docente\"}}},\"fields\":[{\"name\":\"docente\",\"label\":\"docente\",\"type\":\"text\",\"is_name\":false,\"storage\":\"text\"},{\"name\":\"apellido\",\"label\":\"apellido\",\"type\":\"text\",\"is_name\":false,\"storage\":\"text\"},{\"name\":\"nombres\",\"label\":\"nombres\",\"type\":\"text\",\"is_name\":false,\"storage\":\"text\"},{\"name\":\"cargo\",\"label\":\"cargo\",\"type\":\"text\",\"is_name\":false,\"storage\":\"text\"},{\"name\":\"email\",\"label\":\"email\",\"type\":\"email\",\"is_name\":false,\"storage\":\"text\"},{\"name\":\"email_alternativo\",\"label\":\"email alternativo\",\"type\":\"email\",\"is_name\":false,\"storage\":\"text\"},{\"name\":\"jefe\",\"label\":\"jefe\",\"type\":\"text\",\"is_name\":false,\"storage\":\"text\"}]}",
        json,
    );
}

test "stringifies integer and boolean record fields" {
    const cargo: aida.DefinedType(aida.cargo) = .{
        .cargo = "JTP",
        .denominacion = "Jefe de Trabajos Prácticos",
        .orden = 4,
        .puede_dirigir = true,
    };
    var buf: [256]u8 = undefined;
    try expectEqualStrings(
        "{\"cargo\":\"JTP\",\"denominacion\":\"Jefe de Trabajos Prácticos\",\"orden\":4,\"puede_dirigir\":true}",
        try zigma_json.stringifyRecord(cargo, &buf),
    );
}

test "stringifies a fecha field as a JSON object" {
    const clase: aida.DefinedType(aida.clase) = .{
        .periodo = "1C2024",
        .materia = "AlgoI",
        .orden = 1,
        .fecha = .{ .@"año" = 2024, .mes = 3, .@"día" = 15 },
        .tema = "intro",
    };
    var buf: [256]u8 = undefined;
    try expectEqualStrings(
        "{\"periodo\":\"1C2024\",\"materia\":\"AlgoI\",\"orden\":1,\"fecha\":{\"año\":2024,\"mes\":3,\"día\":15},\"tema\":\"intro\"}",
        try zigma_json.stringifyRecord(clase, &buf),
    );
}

test "stringifies a catalog of entity Infos from entity_defs" {
    var buf: [16384]u8 = undefined;
    const json = try zigma_json.stringifyEntityCatalog(aida.type_defs, aida.entity_defs, &buf);
    try std.testing.expect(json[0] == '[');
    try std.testing.expect(json[json.len - 1] == ']');
    try std.testing.expect(std.mem.startsWith(u8, json, "[{\"name\":\"docentes\""));
    try std.testing.expect(std.mem.indexOf(u8, json, "{\"name\":\"materias\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "{\"name\":\"mesas\"") != null);
}

test "stringifies a catalog from a system that is not aida" {
    const ItemRow = zigma.RecordInstanceType(tiny.type_defs, tiny.item);
    const row: ItemRow = .{ .id = "1", .nombre = "uno" };
    var row_buf: [64]u8 = undefined;
    try expectEqualStrings(
        "{\"id\":\"1\",\"nombre\":\"uno\"}",
        try zigma_json.stringifyRecord(row, &row_buf),
    );

    var buf: [512]u8 = undefined;
    try expectEqualStrings(
        "[{\"name\":\"items\",\"pk\":[\"id\"],\"uks\":{},\"fks\":{},\"fields\":[{\"name\":\"id\",\"label\":\"id\",\"type\":\"text\",\"is_name\":false,\"storage\":\"text\"},{\"name\":\"nombre\",\"label\":\"nombre\",\"type\":\"text\",\"is_name\":false,\"storage\":\"text\"}]}]",
        try zigma_json.stringifyEntityCatalog(tiny.type_defs, tiny.entity_defs, &buf),
    );
}

test "a struct field is object storage with nested fields" {
    var buf: [2048]u8 = undefined;
    const json = try zigma_json.stringifyEntitySchema(aida.type_defs, "clases", aida.clases, &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "{\"name\":\"fecha\",\"label\":\"fecha\",\"type\":\"fecha\",\"is_name\":false,\"storage\":\"object\",\"fields\":[{\"name\":\"año\",\"storage\":\"integer\"},{\"name\":\"mes\",\"storage\":\"integer\"},{\"name\":\"día\",\"storage\":\"integer\"}]}") != null);
}

test "parseFieldValue rejects a non-integer string" {
    try std.testing.expectError(error.InvalidValue, zigma_json.parseFieldValue(i64, "abc"));
    try std.testing.expectError(error.InvalidValue, zigma_json.parseFieldValue(i64, ""));
}

test "parseFieldValue parses an integer string" {
    try std.testing.expect(try zigma_json.parseFieldValue(i64, "3") == 3);
}

test "parseFieldValue parses a struct from JSON object" {
    const Stamp = struct { y: u16, m: u8, d: u8 };
    const got = try zigma_json.parseFieldValue(Stamp, "{\"y\":2024,\"m\":3,\"d\":15}");
    try std.testing.expect(got.y == 2024);
    try std.testing.expect(got.m == 3);
    try std.testing.expect(got.d == 15);
}

test "parseFieldValue rejects invalid struct JSON" {
    const Stamp = struct { y: u16, m: u8, d: u8 };
    try std.testing.expectError(error.InvalidValue, zigma_json.parseFieldValue(Stamp, "foo"));
    try std.testing.expectError(error.InvalidValue, zigma_json.parseFieldValue(Stamp, "{\"y\":\"nope\",\"m\":3,\"d\":15}"));
}

fn sliceInside(haystack: []const u8, needle: []const u8) bool {
    const start = @intFromPtr(haystack.ptr);
    const ptr = @intFromPtr(needle.ptr);
    return ptr >= start and ptr + needle.len <= start + haystack.len;
}

test "parseFieldValue struct text fields alias the JSON cell" {
    const Row = struct { name: []const u8, n: i64 };
    const json = "{\"name\":\"hello\",\"n\":3}";
    const got = try zigma_json.parseFieldValue(Row, json);
    try expectEqualStrings("hello", got.name);
    try std.testing.expect(got.n == 3);
    try std.testing.expect(sliceInside(json, got.name));
}

test "parseFieldValue rejects struct text that would allocate a copy" {
    const Row = struct { name: []const u8 };
    try std.testing.expectError(
        error.InvalidValue,
        zigma_json.parseFieldValue(Row, "{\"name\":\"line\\nbreak\"}"),
    );
}
