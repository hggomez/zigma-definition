const std = @import("std");
const zigma = @import("zigma");
const aida = @import("aida");
const system = @import("aida_system");
const contract = @import("compile_errors/fixtures/concrete_entities.zig");

fn isEnabled(value: contract.Thing) bool {
    return value.enabled;
}

test "concrete entity works in functions and collections without constructing Framework" {
    // No se accede a contract.Model: la fila ya es utilizable por sí sola.
    const row: contract.Thing = .{
        .tenant = "acme",
        .id = 7,
        .label = "Ada",
        .note = null,
        .enabled = true,
        .stamp = .{ .tick = 42 },
    };
    const rows = [_]contract.Thing{row};
    try std.testing.expect(isEnabled(rows[0]));
    try std.testing.expect(rows[0].stamp.?.tick == 42);
    try std.testing.expect(@TypeOf(rows[0]) == contract.Thing);
}

test "concrete rows preserve record domains and apply effective PK nullability" {
    const Record = zigma.RecordInstanceType(contract.type_defs, contract.fields);
    const Thing = contract.Thing;
    try std.testing.expect(@FieldType(Record, "tenant") == ?[]const u8);
    try std.testing.expect(@FieldType(Record, "id") == ?i64);
    try std.testing.expect(@FieldType(Thing, "tenant") == []const u8);
    try std.testing.expect(@FieldType(Thing, "id") == i64);
    try std.testing.expect(@FieldType(Thing, "label") == []const u8);
    try std.testing.expect(@FieldType(Thing, "note") == ?[]const u8);
    try std.testing.expect(@FieldType(Thing, "enabled") == bool);
    try std.testing.expect(@FieldType(Thing, "stamp") == ?contract.Stamp);
    try std.testing.expect(@FieldType(contract.Item, "id") == i64);
    try std.testing.expect(contract.fields.id.nullable);
}

test "concrete rows contain only declared data fields and no defaults or metadata declarations" {
    const info = @typeInfo(contract.Thing).@"struct";
    const expected = .{ "tenant", "id", "label", "note", "enabled", "stamp" };
    try std.testing.expect(info.field_names.len == expected.len);
    inline for (expected, 0..) |name, i| {
        try std.testing.expectEqualStrings(name, info.field_names[i]);
        try std.testing.expect(info.field_attrs[i].default_value_ptr == null);
        try std.testing.expect(!info.field_attrs[i].@"comptime");
    }
    try std.testing.expect(info.decl_names.len == 0);
}

test "completeEntity accepts descriptive definitions and fills omitted collections" {
    const definition = .{ .fields = contract.fields, .pk = .{ "tenant", "id", "id" } };
    const info = comptime zigma.completeEntity(definition);
    try std.testing.expect(info.pk.len == 2);
    try std.testing.expectEqualStrings("tenant", info.pk[0]);
    try std.testing.expectEqualStrings("id", info.pk[1]);
    try std.testing.expect(!info.fields.id.nullable and !info.fields.tenant.nullable);
    try std.testing.expect(info.fields.note.nullable);
    try std.testing.expectEqualStrings("note", info.fields.note.label);
    inline for (.{ "fks", "uks", "rules" }) |name| {
        try std.testing.expect(@typeInfo(@TypeOf(@field(info, name))).@"struct".field_names.len == 0);
    }
    try std.testing.expect(zigma.completeRecord(contract.fields).id.nullable);
}

test "extractPk accepts a descriptive definition and preserves original record metadata" {
    const definition = .{ .fields = contract.fields, .pk = .{ "tenant", "id" } };
    const extracted = comptime zigma.extractPk(definition);
    try std.testing.expect(@typeInfo(@TypeOf(extracted)).@"struct".field_names.len == 2);
    try std.testing.expect(extracted.id.nullable);
    try std.testing.expect(!@hasField(@TypeOf(extracted.tenant), "nullable"));
    try std.testing.expectEqualStrings("Organización", extracted.tenant.label);
    try std.testing.expectEqualStrings("Identificador local", extracted.id.description);
    const Inherited = zigma.RecordInstanceType(contract.type_defs, extracted);
    try std.testing.expect(@FieldType(Inherited, "id") == ?i64);
}

test "Framework Row returns exactly the registered type with or without defineEntities" {
    try std.testing.expect(contract.registrations.things.Type == contract.Thing);
    try std.testing.expect(contract.Model.Row("things") == contract.Thing);
    const Direct = zigma.Framework(contract.type_defs, .{
        .things = .{ .Type = contract.Thing, .definition = contract.thing_def },
    });
    try std.testing.expect(Direct.Row("things") == contract.Thing);
    try std.testing.expect(zigma.Entity(contract.type_defs, contract.thing_def) == contract.Thing);
}

test "self relations and normalized dependencies survive registration" {
    const info = contract.Model.info.things;
    try std.testing.expectEqualStrings("things", info.fks.parent.entity);
    try std.testing.expectEqualStrings("tenant", info.fks.parent.fields.tenant);
    try std.testing.expectEqualStrings("id", info.fks.parent.fields.id);
    try std.testing.expect(info.pk.len == 2);
    try std.testing.expectEqualStrings("label", info.uks.by_label[0]);
    try std.testing.expectEqualStrings("note", info.rules.display.fields[0]);
    try std.testing.expectEqualStrings("label", info.rules.display.fields[1]);
}

test "core accepts circular registrations referencing complete PK and UK" {
    const Model = contract.CircularModel;
    try std.testing.expect(Model.Row("lefts") == contract.Left);
    try std.testing.expect(Model.Row("rights") == contract.Right);
    try std.testing.expectEqualStrings("code", Model.info.lefts.fks.right.fields.right_code);
    try std.testing.expectEqualStrings("id", Model.info.rights.fks.left.fields.left_id);
}

test "patches and filters retain presence semantics for registered entities" {
    const Model = contract.Model;
    const Patch = Model.Patch("things");
    try std.testing.expect(!@hasField(Patch, "tenant") and !@hasField(Patch, "id"));
    var patch: Patch = .{};
    try std.testing.expect(patch.note == .unset and patch.enabled == .unset);
    patch.note = .{ .set = null };
    try std.testing.expect(patch.note == .set and patch.note.set == null);
    patch.note = .{ .set = "null" };
    try std.testing.expectEqualStrings("null", patch.note.set.?);
    patch.enabled = .{ .set = false };
    try std.testing.expect(!patch.enabled.set);
    const Filters = Model.Filters("things");
    try std.testing.expect(@FieldType(Filters, "note") == ?[]const u8);
    var filters: Filters = .{};
    try std.testing.expect(filters.id == null and filters.stamp == null);
    filters.id = 0;
    filters.enabled = false;
    filters.stamp = .{ .tick = 1 };
    try std.testing.expect(filters.id.? == 0 and !filters.enabled.? and filters.stamp.?.tick == 1);
}

test "std json serializes concrete data without a wrapper or extra fields" {
    const row: contract.Thing = .{
        .tenant = "acme",
        .id = 7,
        .label = "Ada",
        .note = null,
        .enabled = false,
        .stamp = .{ .tick = 42 },
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.json.Stringify.value(row, .{}, &output.writer);
    try std.testing.expectEqualStrings(
        "{\"tenant\":\"acme\",\"id\":7,\"label\":\"Ada\",\"note\":null,\"enabled\":false,\"stamp\":{\"tick\":42}}",
        output.written(),
    );
}

test "Model info serializes exactly the normalized definition without registered types" {
    var expected: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer expected.deinit();
    const info = comptime zigma.completeEntity(contract.thing_def);
    try std.json.Stringify.value(.{ .things = info }, .{}, &expected.writer);
    var actual: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer actual.deinit();
    try std.json.Stringify.value(contract.Model.info, .{}, &actual.writer);
    try std.testing.expectEqualStrings(expected.written(), actual.written());
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, actual.written(), .{});
    defer parsed.deinit();
    const entity = parsed.value.object.get("things").?.object;
    try std.testing.expect(entity.count() == 5);
    try std.testing.expect(entity.get("Type") == null and entity.get("definition") == null);
    try std.testing.expect(entity.get("rules").?.object.get("display") != null);
}

test "AIDA publishes eleven concrete types registered under the existing table names" {
    const types = .{
        .docentes = aida.Docente,
        .materias = aida.Materia,
        .periodos = aida.Periodo,
        .cursos = aida.Curso,
        .clases = aida.Clase,
        .alumnos = aida.Alumno,
        .preguntas = aida.Pregunta,
        .opciones = aida.Opcion,
        .inscripciones = aida.Inscripcion,
        .presencias = aida.Presencia,
        .mesas = aida.Mesa,
    };
    const names = @typeInfo(@TypeOf(types)).@"struct".field_names;
    try std.testing.expect(@typeInfo(@TypeOf(aida.entity_defs)).@"struct".field_names.len == names.len);
    inline for (names) |name| {
        try std.testing.expect(aida.Model.Row(name) == @field(types, name));
        try std.testing.expect(@field(aida.entity_defs, name).Type == @field(types, name));
    }
    try std.testing.expect(aida.Docente == zigma.Entity(aida.type_defs, aida.docente_def));
    const Cargo = aida.Cargo;
    try std.testing.expect(@FieldType(Cargo, "cargo") == ?[]const u8);
}

test "AIDA seed collections and whole row business validation use concrete types" {
    inline for (@typeInfo(@TypeOf(system.seeds)).@"struct".field_names) |name| {
        const Seed = @typeInfo(@TypeOf(@field(system.seeds, name))).array.child;
        try std.testing.expect(Seed == aida.Model.Row(name));
    }
    const validate: *const fn (aida.Docente) aida.DocenteValidationError!void = &aida.validarDocente;
    var row: aida.Docente = system.seeds.docentes[0];
    row.cargo = "teorico";
    row.experiencia = 4;
    try std.testing.expectError(error.TeoricoRequiereCincoAniosExperiencia, validate(row));
    row.experiencia = 5;
    try validate(row);
}
