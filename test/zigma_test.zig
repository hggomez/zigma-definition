//! Port of aida-test.ts. The positive cases live here; the negative cases
//! (the @ts-expect-error ones of the TypeScript version) are the expected
//! compile errors in test/compile_errors, driven by build.zig.

const std = @import("std");
const zigma = @import("zigma");
const aida = @import("aida");

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

fn expectNames(actual: anytype, comptime expected: []const []const u8) !void {
    try expect(actual.len == expected.len);
    inline for (expected, 0..) |name, i| {
        try expectEqualStrings(name, actual[i]);
    }
}

fn fieldNames(comptime T: type) []const [:0]const u8 {
    return @typeInfo(T).@"struct".field_names;
}

// aida example

test "deduces the record instance type" {
    const Cargo = zigma.RecordInstanceType(aida.type_defs, aida.cargo);
    const jtp: Cargo = .{
        .cargo = "JTP",
        .denominacion = "Jefe de Trabajos Prácticos",
        .orden = 4,
        .puede_dirigir = true,
    };
    try expectEqualStrings("JTP", jtp.cargo);
    try expect(jtp.orden == 4);
    try expect(jtp.puede_dirigir);
    // the equivalent of the mutual assignability of the TypeScript test:
    // the deduced type has exactly these fields, with exactly these types
    comptime {
        std.debug.assert(fieldNames(Cargo).len == 4);
        std.debug.assert(@FieldType(Cargo, "cargo") == []const u8);
        std.debug.assert(@FieldType(Cargo, "denominacion") == []const u8);
        std.debug.assert(@FieldType(Cargo, "orden") == i64);
        std.debug.assert(@FieldType(Cargo, "puede_dirigir") == bool);
    }
}

test "types record instances anywhere with DefinedType" {
    // a typed declaration: the anonymous literal is de-anonymized (coerced
    // and checked) right here, against the declared type
    const titular: aida.DefinedType(aida.cargo) = .{
        .cargo = "TIT",
        .denominacion = "Titular",
        .orden = 1,
        .puede_dirigir = true,
    };
    // a valid instance compiles and passes the validation:
    try aida.validarCargo(titular);
    // and the validation logic runs over the typed instance:
    try std.testing.expectError(error.AyudanteNoPuedeDirigir, aida.validarCargo(.{
        .cargo = "AY1",
        .denominacion = "Ayudante de primera",
        .orden = 5,
        .puede_dirigir = true,
    }));
}

test "completes a record def into a record info" {
    const materia_info = zigma.completeRecord(aida.materia);
    try expectEqualStrings("text", materia_info.materia.type);
    try expectEqualStrings("materia", materia_info.materia.label);
    try expect(materia_info.materia.nullable);
    try expect(!materia_info.materia.is_name);
    try expectEqualStrings("", materia_info.materia.description);
    try expectEqualStrings("denominación", materia_info.denominacion.label);
    try expect(!materia_info.denominacion.nullable);
    try expect(materia_info.denominacion.is_name);
    try expectEqualStrings("si corresponde a más de una carrera, aclarar en el nombre", materia_info.denominacion.description);
}

test "completes preserving the field set, and derives the label from the name" {
    const cargo_info = zigma.completeRecord(aida.cargo);
    try expectEqualStrings("text", cargo_info.cargo.type);
    try expectEqualStrings("integer", cargo_info.orden.type);
    // '_' becomes ' ' in the derived label:
    try expectEqualStrings("puede dirigir", cargo_info.puede_dirigir.label);
    comptime {
        // the completion preserves the field set (no more, no less), and
        // every field is a full FieldInfo (label, nullable and description
        // are no longer optional)
        std.debug.assert(fieldNames(@TypeOf(cargo_info)).len == 4);
        std.debug.assert(!@hasField(@TypeOf(cargo_info), "inexistente"));
        std.debug.assert(@FieldType(@TypeOf(cargo_info), "cargo") == zigma.FieldInfo);
        std.debug.assert(@FieldType(@TypeOf(cargo_info), "puede_dirigir") == zigma.FieldInfo);
    }
}

// aida entities

test "keeps the pk names, in order" {
    try expectNames(aida.cursos.pk, &.{ "periodo", "materia" });
    try expectNames(aida.clases.pk, &.{ "periodo", "materia", "orden" });
}

test "extracts the pk fields with their exact types and order" {
    const cursos_pk_fields = zigma.extractPk(aida.cursos);
    comptime {
        std.debug.assert(fieldNames(@TypeOf(cursos_pk_fields)).len == 2);
        std.debug.assert(eqlComptime(fieldNames(@TypeOf(cursos_pk_fields))[0], "periodo"));
        std.debug.assert(eqlComptime(fieldNames(@TypeOf(cursos_pk_fields))[1], "materia"));
        // 'docente' is a field of cursos but is not part of the pk:
        std.debug.assert(!@hasField(@TypeOf(cursos_pk_fields), "docente"));
        // the extracted field defs keep their exact literal type, with the
        // properties they had in the original record (periodo has a
        // description, materia does not):
        std.debug.assert(@hasField(@TypeOf(cursos_pk_fields.periodo), "description"));
        std.debug.assert(!@hasField(@TypeOf(cursos_pk_fields.materia), "description"));
    }
    try expectEqualStrings("text", cursos_pk_fields.periodo.type);
    try expectEqualStrings("bimestre, cuatrimestre, etc...", cursos_pk_fields.periodo.description);
}

test "inherits pk fields into other entities" {
    // curso got all its fields from the periodos, materias and docentes pks:
    comptime {
        const curso_names = fieldNames(@TypeOf(aida.curso));
        std.debug.assert(curso_names.len == 3);
        std.debug.assert(eqlComptime(curso_names[0], "periodo"));
        std.debug.assert(eqlComptime(curso_names[1], "materia"));
        std.debug.assert(eqlComptime(curso_names[2], "docente"));
        // clase extends the cursos pk with its own fields:
        const clase_names = fieldNames(@TypeOf(aida.clase));
        std.debug.assert(clase_names.len == 5);
        std.debug.assert(eqlComptime(clase_names[0], "periodo"));
        std.debug.assert(eqlComptime(clase_names[1], "materia"));
        std.debug.assert(eqlComptime(clase_names[2], "orden"));
        std.debug.assert(eqlComptime(clase_names[3], "fecha"));
        std.debug.assert(eqlComptime(clase_names[4], "tema"));
    }
    // the inherited fields keep their type:
    try expectEqualStrings("text", aida.clases.fields.periodo.type);
}

test "chains pk inheritance (clases → preguntas → opciones)" {
    try expectNames(aida.opciones.pk, &.{ "periodo", "materia", "orden", "pregunta", "opcion" });
    comptime {
        const opcion_names = fieldNames(@TypeOf(aida.opcion));
        std.debug.assert(opcion_names.len == 6);
        std.debug.assert(eqlComptime(opcion_names[0], "periodo"));
        std.debug.assert(eqlComptime(opcion_names[1], "materia"));
        std.debug.assert(eqlComptime(opcion_names[2], "orden"));
        std.debug.assert(eqlComptime(opcion_names[3], "pregunta"));
        std.debug.assert(eqlComptime(opcion_names[4], "opcion"));
        std.debug.assert(eqlComptime(opcion_names[5], "detalle"));
    }
}

test "merges overlapping pks without repeating (inscripciones + clases)" {
    // periodo and materia are in both pks and must appear once, in order
    const merged = zigma.mergePk(.{ aida.inscripciones.pk, aida.clases.pk });
    try expectNames(merged, &.{ "periodo", "materia", "alumno", "orden" });
    // presencias uses that merge as its pk:
    try expectNames(aida.presencias.pk, &.{ "periodo", "materia", "alumno", "orden" });
    // and the fields merge dedups the shared fields by itself:
    comptime std.debug.assert(fieldNames(@TypeOf(aida.presencia)).len == 4);
    // the whole chain still deduces the instance type:
    const Presencia = zigma.RecordInstanceType(aida.type_defs, aida.presencia);
    const una_presencia: Presencia = .{ .periodo = "2026-1c", .materia = "AlgoI", .alumno = "L1234", .orden = 1 };
    try expectEqualStrings("AlgoI", una_presencia.materia);
    try expect(una_presencia.orden == 1);
}

// aida fks, uks and is_name

test "keeps the fks as written (array form)" {
    try expectEqualStrings("inscripciones", aida.presencias.fks.inscripciones.entity);
    try expectNames(aida.presencias.fks.inscripciones.fields, &.{ "periodo", "materia", "alumno" });
    try expectEqualStrings("clases", aida.presencias.fks.clases.entity);
    try expectNames(aida.presencias.fks.clases.fields, &.{ "periodo", "materia", "orden" });
}

test "represents a reflexive fk with renamed fields (jefe → docente)" {
    try expectEqualStrings("docentes", aida.docentes.fks.jefe.entity);
    try expectEqualStrings("docente", aida.docentes.fks.jefe.fields.jefe);
}

test "represents two fks to the same entity (mesas: presidente y vocal)" {
    try expectEqualStrings("docentes", aida.mesas.fks.presidente.entity);
    try expectEqualStrings("docente", aida.mesas.fks.presidente.fields.presidente);
    try expectEqualStrings("docentes", aida.mesas.fks.vocal.entity);
    try expectEqualStrings("docente", aida.mesas.fks.vocal.fields.vocal);
}

test "marks the is_name field and completes it as false elsewhere" {
    try expect(aida.materia.denominacion.is_name);
    // at the Def level the other fields do not even have the property
    // (the equivalent of the @ts-expect-error of the TypeScript test):
    comptime std.debug.assert(!@hasField(@TypeOf(aida.materia.materia), "is_name"));
    // the completion makes it explicit everywhere:
    const materia_info = zigma.completeRecord(aida.materia);
    try expect(!materia_info.materia.is_name);
    try expect(materia_info.denominacion.is_name);
}

test "defineTypes accepts the anonymous TypeDef shape too" {
    const custom_types = zigma.defineTypes(.{ .texto = .{ .Type = []const u8 } });
    const Row = zigma.RecordInstanceType(custom_types, zigma.record(custom_types, .{
        .x = .{ .type = "texto" },
    }));
    comptime std.debug.assert(@FieldType(Row, "x") == []const u8);
    const row: Row = .{ .x = "hola" };
    try expectEqualStrings("hola", row.x);
}

// system-level checks (a fk against a uk of the target entity is accepted)

const apuntes = zigma.defineEntity(.{
    .pk = .{"apunte"},
    .fks = .{ .materia_por_nombre = .{ .entity = "materias", .fields = .{ .denominacion_materia = "denominacion" } } },
    .fields = zigma.record(aida.type_defs, .{
        .apunte = .{ .type = "text" },
        .denominacion_materia = .{ .type = "text" },
    }),
});
const mini_system = zigma.defineEntities(.{ .materias = aida.materias, .apuntes = apuntes });

test "cross-checks the fks of the whole system" {
    // the aida entity_defs already went through defineEntities;
    // spot-check it kept everything:
    comptime std.debug.assert(fieldNames(@TypeOf(aida.entity_defs)).len == 11);
    try expectNames(aida.entity_defs.presencias.pk, &.{ "periodo", "materia", "alumno", "orden" });
    // a fk against a uk of the target entity is accepted (mini_system compiled):
    comptime std.debug.assert(fieldNames(@TypeOf(mini_system)).len == 2);
    try expectEqualStrings("denominacion", mini_system.apuntes.fks.materia_por_nombre.fields.denominacion_materia);
}

// aida entity completion (Def → Info)

test "normalizes array-form fks to the source→target map form" {
    const cursos_info = zigma.completeEntity(aida.cursos);
    try expectEqualStrings("periodos", cursos_info.fks.periodos.entity);
    try expectEqualStrings("periodo", cursos_info.fks.periodos.fields.periodo);
    try expectEqualStrings("materia", cursos_info.fks.materias.fields.materia);
    try expectEqualStrings("docente", cursos_info.fks.responsable.fields.docente);
    comptime {
        std.debug.assert(!@hasField(@TypeOf(cursos_info.fks), "inexistente"));
        // after completion the array form is gone: fields is always a map
        // (a struct, not an indexable list)
        const FksFields = @TypeOf(cursos_info.fks.periodos.fields);
        std.debug.assert(@typeInfo(FksFields) == .@"struct");
        std.debug.assert(!@typeInfo(FksFields).@"struct".is_tuple);
    }
}

test "keeps map-form fks as they are" {
    const mesas_info = zigma.completeEntity(aida.mesas);
    try expectEqualStrings("docentes", mesas_info.fks.presidente.entity);
    try expectEqualStrings("docente", mesas_info.fks.presidente.fields.presidente);
    try expectEqualStrings("periodo", mesas_info.fks.cursos.fields.periodo);
    try expectEqualStrings("materia", mesas_info.fks.cursos.fields.materia);
}

// periodo and materia appear twice in the concatenation:
const presencias_alt = zigma.defineEntity(.{
    .pk = aida.inscripciones.pk ++ aida.clases.pk,
    .fields = aida.presencia,
});

test "dedups the pk, so overlapping pks can be concatenated without mergePk" {
    comptime std.debug.assert(presencias_alt.pk.len == 6);
    const presencias_alt_info = zigma.completeEntity(presencias_alt);
    try expectNames(presencias_alt_info.pk, &.{ "periodo", "materia", "alumno", "orden" });
}

test "completes the fields and keeps the uks" {
    const materias_info = zigma.completeEntity(aida.materias);
    const materia_info = zigma.completeRecord(aida.materia);
    try expectEqualStrings(materia_info.denominacion.label, materias_info.fields.denominacion.label);
    try expect(materias_info.fields.denominacion.is_name);
    try expectNames(materias_info.uks.denominacion, &.{"denominacion"});
    // the defaulted empty fks stay explicit and empty:
    comptime std.debug.assert(fieldNames(@TypeOf(materias_info.fks)).len == 0);
}

fn eqlComptime(comptime a: []const u8, comptime b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
