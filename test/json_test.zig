//! JSON writer for record instances: field names and values come from the
//! instance, not from a handwritten format string.

const std = @import("std");
const zigma = @import("zigma");
const aida = @import("aida");
const zigma_json = @import("zigma_json");
const tiny = @import("tiny_system.zig");

const expectEqualStrings = std.testing.expectEqualStrings;

test "nullable record values serialize as JSON null or their domain value" {
    const Row = zigma.RecordInstanceType(aida.type_defs, .{
        .text = .{ .type = "text" },
        .number = .{ .type = "integer" },
        .flag = .{ .type = "boolean" },
        .date = .{ .type = "fecha" },
    });
    var buf: [256]u8 = undefined;
    const empty: Row = .{ .text = null, .number = null, .flag = null, .date = null };
    try expectEqualStrings(
        "{\"text\":null,\"number\":null,\"flag\":null,\"date\":null}",
        try zigma_json.stringifyRecord(empty, &buf),
    );
    const present: Row = .{
        .text = "null",
        .number = 0,
        .flag = false,
        .date = .{ .@"año" = 2024, .mes = 2, .@"día" = 29 },
    };
    try expectEqualStrings(
        "{\"text\":\"null\",\"number\":0,\"flag\":false,\"date\":{\"año\":2024,\"mes\":2,\"día\":29}}",
        try zigma_json.stringifyRecord(present, &buf),
    );
    var short_buf: [8]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, zigma_json.stringifyRecord(empty, &short_buf));
}

test "fieldStorage unwraps optionals to the child widget shape" {
    try expectEqualStrings("text", zigma_json.fieldStorage(?[]const u8));
    try expectEqualStrings("integer", zigma_json.fieldStorage(?i64));
    try expectEqualStrings("boolean", zigma_json.fieldStorage(?bool));
    try expectEqualStrings("object", zigma_json.fieldStorage(?aida.Fecha));
}

test "empty cell is Zig null for optionals and invalid for required text" {
    try std.testing.expect((try zigma_json.parseFieldValue(?[]const u8, "")) == null);
    try std.testing.expect((try zigma_json.parseFieldValue(?i64, "")) == null);
    try std.testing.expect((try zigma_json.parseFieldValue(?bool, "")) == null);
    try std.testing.expect((try zigma_json.parseFieldValue(?aida.Fecha, "")) == null);
    try std.testing.expectError(error.InvalidValue, zigma_json.parseFieldValue([]const u8, ""));
}

test "nullable query types decode a supplied value without inventing a null literal" {
    try expectEqualStrings("null", (try zigma_json.parseFieldValue(?[]const u8, "null")).?);
    try std.testing.expect((try zigma_json.parseFieldValue(?i64, "0")).? == 0);
    try std.testing.expect((try zigma_json.parseFieldValue(?bool, "false")).? == false);
    try std.testing.expectError(error.InvalidValue, zigma_json.parseFieldValue(?i64, "null"));
    const date = (try zigma_json.parseFieldValue(?aida.Fecha, "{\"año\":2024,\"mes\":2,\"día\":29}")).?;
    try std.testing.expect(date.@"año" == 2024 and date.mes == 2 and date.@"día" == 29);
}

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
        "{\"name\":\"materias\",\"pk\":[\"materia\"],\"uks\":{\"denominacion\":[\"denominacion\"]},\"fks\":{},\"fields\":[{\"name\":\"materia\",\"label\":\"materia\",\"type\":\"text\",\"is_name\":false,\"nullable\":false,\"storage\":\"text\"},{\"name\":\"denominacion\",\"label\":\"denominación\",\"type\":\"text\",\"is_name\":true,\"nullable\":false,\"storage\":\"text\"}]}",
        try zigma_json.stringifyEntitySchema(aida.Model, "materias", &buf),
    );
}

test "stringifies entity fks as source-to-target maps" {
    var buf: [2048]u8 = undefined;
    const json = try zigma_json.stringifyEntitySchema(aida.Model, "docentes", &buf);
    try expectEqualStrings(
        "{\"name\":\"docentes\",\"pk\":[\"docente\"],\"uks\":{},\"fks\":{\"jefe\":{\"entity\":\"docentes\",\"fields\":{\"jefe\":\"docente\"}}},\"fields\":[{\"name\":\"docente\",\"label\":\"docente\",\"type\":\"text\",\"is_name\":false,\"nullable\":false,\"storage\":\"text\"},{\"name\":\"apellido\",\"label\":\"apellido\",\"type\":\"text\",\"is_name\":false,\"nullable\":true,\"storage\":\"text\"},{\"name\":\"nombres\",\"label\":\"nombres\",\"type\":\"text\",\"is_name\":false,\"nullable\":false,\"storage\":\"text\"},{\"name\":\"cargo\",\"label\":\"cargo\",\"type\":\"text\",\"is_name\":false,\"nullable\":true,\"storage\":\"text\"},{\"name\":\"email\",\"label\":\"email\",\"type\":\"email\",\"is_name\":false,\"nullable\":true,\"storage\":\"text\"},{\"name\":\"email_alternativo\",\"label\":\"email alternativo\",\"type\":\"email\",\"is_name\":false,\"nullable\":true,\"storage\":\"text\"},{\"name\":\"jefe\",\"label\":\"jefe\",\"type\":\"text\",\"is_name\":false,\"nullable\":true,\"storage\":\"text\"},{\"name\":\"telefono\",\"label\":\"telefono\",\"type\":\"text\",\"is_name\":false,\"nullable\":true,\"storage\":\"text\"},{\"name\":\"experiencia\",\"label\":\"experiencia\",\"type\":\"integer\",\"is_name\":false,\"nullable\":true,\"storage\":\"integer\"},{\"name\":\"esImportador\",\"label\":\"esImportador\",\"type\":\"boolean\",\"is_name\":false,\"nullable\":true,\"storage\":\"boolean\"}]}",
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
    const json = try zigma_json.stringifyEntityCatalog(aida.Model, &buf);
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
        "[{\"name\":\"items\",\"pk\":[\"id\"],\"uks\":{},\"fks\":{},\"fields\":[{\"name\":\"id\",\"label\":\"id\",\"type\":\"text\",\"is_name\":false,\"nullable\":false,\"storage\":\"text\"},{\"name\":\"nombre\",\"label\":\"nombre\",\"type\":\"text\",\"is_name\":false,\"nullable\":true,\"storage\":\"text\"}]}]",
        try zigma_json.stringifyEntityCatalog(zigma.System(tiny.type_defs, tiny.entity_defs), &buf),
    );
}

test "a struct field is object storage with nested fields" {
    var buf: [2048]u8 = undefined;
    const json = try zigma_json.stringifyEntitySchema(aida.Model, "clases", &buf);
    try std.testing.expect(std.mem.indexOf(u8, json, "{\"name\":\"fecha\",\"label\":\"fecha\",\"type\":\"fecha\",\"is_name\":false,\"nullable\":true,\"storage\":\"object\",\"fields\":[{\"name\":\"año\",\"nullable\":false,\"storage\":\"integer\"},{\"name\":\"mes\",\"nullable\":false,\"storage\":\"integer\"},{\"name\":\"día\",\"nullable\":false,\"storage\":\"integer\"}]}") != null);
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

test "record JSON escapes text and property names and preserves Unicode" {
    const key = "nombre\"\\\n\tñ";
    const text = "Profesor \"Juan\"\\aula\nsegunda línea\tñ 😀\r\x01";
    const Row = struct { @"nombre\"\\\n\tñ": []const u8, empty: ?bool };
    const row: Row = .{ .@"nombre\"\\\n\tñ" = text, .empty = null };
    var buf: [512]u8 = undefined;
    const encoded = try zigma_json.stringifyRecord(row, &buf);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try expectEqualStrings(text, parsed.value.object.get(key).?.string);
    try std.testing.expect(parsed.value.object.get("empty").? == .null);
}

test "record arrays escape every element" {
    const Row = struct { name: []const u8 };
    const rows = [_]Row{ .{ .name = "a\"b" }, .{ .name = "c\\d\ne" } };
    var buf: [128]u8 = undefined;
    const encoded = try zigma_json.stringifyRecords(&rows, &buf);
    var parsed = try std.json.parseFromSlice([]Row, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.len == rows.len);
    for (rows, parsed.value) |expected, actual| try expectEqualStrings(expected.name, actual.name);
}

test "record schema escapes labels and names" {
    const name = "campo\"\\\n";
    const label = "Etiqueta \"visible\"\\ruta\nsegunda línea\tñ";
    const info = zigma.completeRecord(zigma.record(zigma.common_type_defs, .{
        .@"campo\"\\\n" = .{ .type = "text", .label = label },
    }));
    var buf: [256]u8 = undefined;
    const encoded = try zigma_json.stringifyRecordSchema(info, &buf);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, encoded, .{});
    defer parsed.deinit();
    try expectEqualStrings(name, parsed.value.array.items[0].object.get("name").?.string);
    try expectEqualStrings(label, parsed.value.array.items[0].object.get("label").?.string);
}

test "escaped output capacity is checked and the caller buffer can be reused" {
    const Row = struct { value: []const u8 };
    var buf: [20]u8 = undefined;
    // La entrada cabe; su representación escapada requiere más espacio.
    try std.testing.expectError(error.NoSpaceLeft, zigma_json.stringifyRecord(Row{ .value = "\n\n\n\n\n\n\n\n" }, &buf));
    try expectEqualStrings("{\"value\":\"ok\"}", try zigma_json.stringifyRecord(Row{ .value = "ok" }, &buf));
    var empty: [0]u8 = .{};
    try std.testing.expectError(error.NoSpaceLeft, zigma_json.stringifyRecords(&[_]Row{}, &empty));
}
