//! Pruebas del descriptor con el vocabulario de AIDA como fixture.
//! Los rechazos genéricos viven en test/compile_errors; las reglas propias de
//! Cargo y Docente y sus rechazos pertenecen a examples/aida/test.

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

// Ejemplo aida.

test "deduces the record instance type" {
    const Cargo = zigma.RecordInstanceType(aida.type_defs, aida.cargo);
    const jtp: Cargo = .{
        .cargo = "JTP",
        .denominacion = "Jefe de Trabajos Prácticos",
        .orden = 4,
        .puede_dirigir = true,
    };
    try expectEqualStrings("JTP", jtp.cargo.?);
    try expect(jtp.orden.? == 4);
    try expect(jtp.puede_dirigir.?);
    // Equivale a la asignabilidad mutua del test TypeScript: el tipo
    // deducido tiene exactamente estos campos, con exactamente estos tipos.
    comptime {
        std.debug.assert(fieldNames(Cargo).len == 4);
        std.debug.assert(@FieldType(Cargo, "cargo") == ?[]const u8);
        std.debug.assert(@FieldType(Cargo, "denominacion") == ?[]const u8);
        std.debug.assert(@FieldType(Cargo, "orden") == ?i64);
        std.debug.assert(@FieldType(Cargo, "puede_dirigir") == ?bool);
    }
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
    // '_' se convierte en ' ' en el label derivado:
    try expectEqualStrings("puede dirigir", cargo_info.puede_dirigir.label);
    comptime {
        // La normalización conserva el conjunto exacto de campos y convierte cada uno
        // en un FieldInfo completo: label, nullable y description
        // ya no son opcionales.
        std.debug.assert(fieldNames(@TypeOf(cargo_info)).len == 4);
        std.debug.assert(!@hasField(@TypeOf(cargo_info), "inexistente"));
        std.debug.assert(@FieldType(@TypeOf(cargo_info), "cargo") == zigma.FieldInfo);
        std.debug.assert(@FieldType(@TypeOf(cargo_info), "puede_dirigir") == zigma.FieldInfo);
    }
}

// Entidades de aida.

test "keeps the pk names, in order" {
    try expectNames(aida.curso_def.pk, &.{ "periodo", "materia" });
    try expectNames(aida.clase_def.pk, &.{ "periodo", "materia", "orden" });
}

test "extracts the pk fields with their exact types and order" {
    const cursos_pk_fields = zigma.extractPk(aida.curso_def);
    comptime {
        std.debug.assert(fieldNames(@TypeOf(cursos_pk_fields)).len == 2);
        std.debug.assert(eqlComptime(fieldNames(@TypeOf(cursos_pk_fields))[0], "periodo"));
        std.debug.assert(eqlComptime(fieldNames(@TypeOf(cursos_pk_fields))[1], "materia"));
        // 'docente' es un campo de cursos, pero no forma parte de la PK:
        std.debug.assert(!@hasField(@TypeOf(cursos_pk_fields), "docente"));
        // Las definiciones extraídas conservan su tipo literal exacto y las
        // propiedades del record original: periodo tiene description;
        // materia no.
        std.debug.assert(@hasField(@TypeOf(cursos_pk_fields.periodo), "description"));
        std.debug.assert(!@hasField(@TypeOf(cursos_pk_fields.materia), "description"));
    }
    try expectEqualStrings("text", cursos_pk_fields.periodo.type);
    try expectEqualStrings("bimestre, cuatrimestre, etc...", cursos_pk_fields.periodo.description);
}

test "inherits pk fields into other entities" {
    // curso obtuvo todos sus campos de las PKs de periodos, materias y docentes:
    comptime {
        const curso_names = fieldNames(@TypeOf(aida.curso_def.fields));
        std.debug.assert(curso_names.len == 3);
        std.debug.assert(eqlComptime(curso_names[0], "periodo"));
        std.debug.assert(eqlComptime(curso_names[1], "materia"));
        std.debug.assert(eqlComptime(curso_names[2], "docente"));
        // clase extiende la PK de cursos con sus propios campos:
        const clase_names = fieldNames(@TypeOf(aida.clase_def.fields));
        std.debug.assert(clase_names.len == 5);
        std.debug.assert(eqlComptime(clase_names[0], "periodo"));
        std.debug.assert(eqlComptime(clase_names[1], "materia"));
        std.debug.assert(eqlComptime(clase_names[2], "orden"));
        std.debug.assert(eqlComptime(clase_names[3], "fecha"));
        std.debug.assert(eqlComptime(clase_names[4], "tema"));
    }
    // Los campos heredados conservan su tipo:
    try expectEqualStrings("text", aida.clase_def.fields.periodo.type);
}

test "chains pk inheritance (clases → preguntas → opciones)" {
    try expectNames(aida.opcion_def.pk, &.{ "periodo", "materia", "orden", "pregunta", "opcion" });
    comptime {
        const opcion_names = fieldNames(@TypeOf(aida.opcion_def.fields));
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
    // periodo y materia están en ambas PKs y deben aparecer una sola vez, en orden.
    const merged = zigma.mergePk(.{ aida.inscripcion_def.pk, aida.clase_def.pk });
    try expectNames(merged, &.{ "periodo", "materia", "alumno", "orden" });
    // presencias usa esa combinación como su PK:
    try expectNames(aida.presencia_def.pk, &.{ "periodo", "materia", "alumno", "orden" });
    // Y la combinación de campos elimina por sí misma los campos compartidos duplicados:
    comptime std.debug.assert(fieldNames(@TypeOf(aida.presencia_def.fields)).len == 4);
    // Toda la cadena sigue deduciendo el tipo de instancia:
    const Presencia = zigma.RecordInstanceType(aida.type_defs, aida.presencia_def.fields);
    const una_presencia: Presencia = .{ .periodo = "2026-1c", .materia = "AlgoI", .alumno = "L1234", .orden = 1 };
    try expectEqualStrings("AlgoI", una_presencia.materia.?);
    try expect(una_presencia.orden.? == 1);
}

// FKs, UKs e is_name de aida.

test "keeps the fks as written (array form)" {
    try expectEqualStrings("inscripciones", aida.presencia_def.fks.inscripciones.entity);
    try expectNames(aida.presencia_def.fks.inscripciones.fields, &.{ "periodo", "materia", "alumno" });
    try expectEqualStrings("clases", aida.presencia_def.fks.clases.entity);
    try expectNames(aida.presencia_def.fks.clases.fields, &.{ "periodo", "materia", "orden" });
}

test "represents a reflexive fk with renamed fields (jefe → docente)" {
    try expectEqualStrings("docentes", aida.docente_def.fks.jefe.entity);
    try expectEqualStrings("docente", aida.docente_def.fks.jefe.fields.jefe);
}

test "represents two fks to the same entity (mesas: presidente y vocal)" {
    try expectEqualStrings("docentes", aida.mesa_def.fks.presidente.entity);
    try expectEqualStrings("docente", aida.mesa_def.fks.presidente.fields.presidente);
    try expectEqualStrings("docentes", aida.mesa_def.fks.vocal.entity);
    try expectEqualStrings("docente", aida.mesa_def.fks.vocal.fields.vocal);
}

test "marks the is_name field and completes it as false elsewhere" {
    try expect(aida.materia.denominacion.is_name);
    // A nivel Def, los demás campos ni siquiera tienen la propiedad;
    // equivale al @ts-expect-error del test TypeScript:
    comptime std.debug.assert(!@hasField(@TypeOf(aida.materia.materia), "is_name"));
    // La normalización la explicita en todos los campos:
    const materia_info = zigma.completeRecord(aida.materia);
    try expect(!materia_info.materia.is_name);
    try expect(materia_info.denominacion.is_name);
}

test "defineTypes accepts the anonymous TypeDef shape too" {
    const custom_types = zigma.defineTypes(.{ .texto = .{ .Type = []const u8 } });
    const Row = zigma.RecordInstanceType(custom_types, zigma.record(custom_types, .{
        .x = .{ .type = "texto" },
    }));
    comptime std.debug.assert(@FieldType(Row, "x") == ?[]const u8);
    const row: Row = .{ .x = "hola" };
    try expectEqualStrings("hola", row.x.?);
}

// Comprobaciones de sistema: se acepta una FK que referencia una UK de la entidad destino.

const apuntes = .{
    .pk = .{"apunte"},
    .fks = .{ .materia_por_nombre = .{ .entity = "materias", .fields = .{ .denominacion_materia = "denominacion" } } },
    .fields = zigma.record(aida.type_defs, .{
        .apunte = .{ .type = "text" },
        .denominacion_materia = .{ .type = "text" },
    }),
};
const mini_system = zigma.defineEntities(.{ .materias = aida.entity_defs.materias, .apuntes = .{ .Type = zigma.Entity(aida.type_defs, apuntes), .definition = apuntes } });

test "cross-checks the fks of the whole system" {
    // entity_defs de aida ya pasó por defineEntities;
    // se comprueba con algunos casos que conservó todo:
    comptime std.debug.assert(fieldNames(@TypeOf(aida.entity_defs)).len == 11);
    try expectNames(aida.entity_defs.presencias.definition.pk, &.{ "periodo", "materia", "alumno", "orden" });
    // Se acepta una FK que referencia una UK de la entidad destino: mini_system compiló.
    comptime std.debug.assert(fieldNames(@TypeOf(mini_system)).len == 2);
    try expectEqualStrings("denominacion", mini_system.apuntes.definition.fks.materia_por_nombre.fields.denominacion_materia);
}

// Normalización de entidades aida: Def → Info.

test "normalizes array-form fks to the source→target map form" {
    const cursos_info = zigma.completeEntity(aida.curso_def);
    try expectEqualStrings("periodos", cursos_info.fks.periodos.entity);
    try expectEqualStrings("periodo", cursos_info.fks.periodos.fields.periodo);
    try expectEqualStrings("materia", cursos_info.fks.materias.fields.materia);
    try expectEqualStrings("docente", cursos_info.fks.responsable.fields.docente);
    comptime {
        std.debug.assert(!@hasField(@TypeOf(cursos_info.fks), "inexistente"));
        // Después de normalizar desaparece la forma de array: fields siempre es un mapa,
        // un struct que no se puede indexar como una lista.
        const FksFields = @TypeOf(cursos_info.fks.periodos.fields);
        std.debug.assert(@typeInfo(FksFields) == .@"struct");
        std.debug.assert(!@typeInfo(FksFields).@"struct".is_tuple);
    }
}

test "keeps map-form fks as they are" {
    const mesas_info = zigma.completeEntity(aida.mesa_def);
    try expectEqualStrings("docentes", mesas_info.fks.presidente.entity);
    try expectEqualStrings("docente", mesas_info.fks.presidente.fields.presidente);
    try expectEqualStrings("periodo", mesas_info.fks.cursos.fields.periodo);
    try expectEqualStrings("materia", mesas_info.fks.cursos.fields.materia);
}

// periodo y materia aparecen dos veces en la concatenación:
const presencias_alt = .{
    .pk = aida.inscripcion_def.pk ++ aida.clase_def.pk,
    .fields = aida.presencia_def.fields,
};

test "dedups the pk, so overlapping pks can be concatenated without mergePk" {
    comptime std.debug.assert(presencias_alt.pk.len == 6);
    const presencias_alt_info = zigma.completeEntity(presencias_alt);
    try expectNames(presencias_alt_info.pk, &.{ "periodo", "materia", "alumno", "orden" });
}

test "completes the fields and keeps the uks" {
    const materias_info = zigma.completeEntity(aida.materia_def);
    const materia_info = zigma.completeRecord(aida.materia);
    try expectEqualStrings(materia_info.denominacion.label, materias_info.fields.denominacion.label);
    try expect(materias_info.fields.denominacion.is_name);
    try expectNames(materias_info.uks.denominacion, &.{"denominacion"});
    // Las FKs vacías por default siguen siendo explícitas y vacías:
    comptime std.debug.assert(fieldNames(@TypeOf(materias_info.fks)).len == 0);
}

fn eqlComptime(comptime a: []const u8, comptime b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
