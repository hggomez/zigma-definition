//! EJEMPLO: el sistema de alumnos (el mismo ejemplo aida de system-design).

const std = @import("std");
const zigma = @import("zigma");

pub const Fecha = struct { @"año": u16, mes: u8, @"día": u8 };

pub const type_defs = zigma.defineTypes(zigma.merge(.{ zigma.common_type_defs, .{
    .fecha = zigma.TypeDef{ .Type = Fecha },
    .email = zigma.common_type_defs.text,
} }));

/// Tipo de instancia de una definición de record, ligado a los type_defs del sistema:
/// DefinedType(cargo) = struct { cargo: ?[]const u8, orden: ?i64, ... }
pub fn DefinedType(comptime rec: anytype) type {
    return zigma.RecordInstanceType(type_defs, rec);
}

pub const cargo = zigma.record(type_defs, .{
    .cargo = .{ .type = "text" },
    .denominacion = .{ .type = "text", .label = "denominación" },
    .orden = .{ .type = "integer" },
    .puede_dirigir = .{ .type = "boolean" },
});

pub const materia = zigma.record(type_defs, .{
    .materia = .{ .type = "text" },
    .denominacion = .{ .type = "text", .label = "denominación", .nullable = false, .is_name = true, .description = "si corresponde a más de una carrera, aclarar en el nombre" },
});

pub const docente = zigma.record(type_defs, .{
    .docente = .{ .type = "text" },
    .apellido = .{ .type = "text", .nullable = true },
    .nombres = .{ .type = "text", .nullable = false },
    .cargo = .{ .type = "text" },
    .email = .{ .type = "email" },
    .email_alternativo = .{ .type = "email" },
    .jefe = .{ .type = "text", .description = "jefe de cátedra (otro docente)" },
    .telefono = .{ .type = "text" },
    .experiencia = .{ .type = "integer" },
    .esImportador = .{ .type = "boolean" }
});

pub const asignacion = zigma.record(type_defs, .{
    .docente = docente.docente,
    .materia = materia.materia,
    .cargo = cargo.cargo,
});

pub const periodo = zigma.record(type_defs, .{
    .periodo = .{ .type = "text", .description = "bimestre, cuatrimestre, etc..." },
});

// Entidades: los nombres plurales envuelven las definiciones de records en singular.

pub const docentes = zigma.defineEntity(.{
    .pk = .{"docente"},
    // FK reflexiva: dentro de su definición, la entidad se referencia por nombre
    // y el campo origen (jefe) se asocia al campo destino (docente).
    .fks = .{ .jefe = .{ .entity = "docentes", .fields = .{ .jefe = "docente" } } },
    .fields = docente,
});
pub const materias = zigma.defineEntity(.{
    .pk = .{"materia"},
    .uks = .{ .denominacion = .{"denominacion"} },
    .fields = materia,
});
pub const periodos = zigma.defineEntity(.{ .pk = .{"periodo"}, .fields = periodo });

pub const curso = zigma.record(type_defs, zigma.merge(.{
    zigma.extractPk(periodos),
    zigma.extractPk(materias),
    zigma.extractPk(docentes), // docente responsable del curso
}));

pub const cursos = zigma.defineEntity(.{
    .pk = .{ "periodo", "materia" },
    .fks = .{
        .periodos = .{ .entity = "periodos", .fields = periodos.pk },
        .materias = .{ .entity = "materias", .fields = materias.pk },
        .responsable = .{ .entity = "docentes", .fields = docentes.pk },
    },
    .fields = curso,
});

pub const clase = zigma.record(type_defs, zigma.merge(.{ zigma.extractPk(cursos), .{
    .orden = .{ .type = "integer" },
    .fecha = .{ .type = "fecha" },
    .tema = .{ .type = "text" },
} }));

pub const clases = zigma.defineEntity(.{
    .pk = zigma.mergePk(.{ cursos.pk, .{"orden"} }),
    .fks = .{ .cursos = .{ .entity = "cursos", .fields = cursos.pk } },
    .fields = clase,
});

pub const alumno = zigma.record(type_defs, .{
    .alumno = .{ .type = "text" },
    .apellido = .{ .type = "text", .nullable = false },
    .nombres = .{ .type = "text", .nullable = false },
    .email = .{ .type = "email" },
});

pub const alumnos = zigma.defineEntity(.{ .pk = .{"alumno"}, .fields = alumno });

pub const pregunta = zigma.record(type_defs, zigma.merge(.{ zigma.extractPk(clases), .{
    .pregunta = .{ .type = "integer" },
    .formulacion = .{ .type = "text", .nullable = false, .label = "formulación", .description = "texto principal de la pregunta" },
    .aclaraciones = .{ .type = "text", .description = "texto que no necesita repetirse cuando se quiera referir a una pregunta por su formulación, pero que es necesario para aclarar el contexto o posibles ambigüedades de la pregunta" },
    .tipo_respuesta = .{ .type = "text", .nullable = false, .label = "tipo" },
} }));

pub const preguntas = zigma.defineEntity(.{
    .pk = zigma.mergePk(.{ clases.pk, .{"pregunta"} }),
    .fks = .{ .clases = .{ .entity = "clases", .fields = clases.pk } },
    .fields = pregunta,
});

pub const opcion = zigma.record(type_defs, zigma.merge(.{ zigma.extractPk(preguntas), .{
    .opcion = .{ .type = "text" },
    .detalle = .{ .type = "text" },
} }));

pub const opciones = zigma.defineEntity(.{
    .pk = zigma.mergePk(.{ preguntas.pk, .{"opcion"} }),
    .fks = .{ .preguntas = .{ .entity = "preguntas", .fields = preguntas.pk } },
    .fields = opcion,
});

pub const inscripcion = zigma.record(type_defs, zigma.merge(.{
    zigma.extractPk(cursos),
    zigma.extractPk(alumnos),
}));

pub const inscripciones = zigma.defineEntity(.{
    .pk = zigma.mergePk(.{ cursos.pk, .{"alumno"} }),
    .fks = .{
        .cursos = .{ .entity = "cursos", .fields = cursos.pk },
        .alumnos = .{ .entity = "alumnos", .fields = alumnos.pk },
    },
    .fields = inscripcion,
});

// PK combinada: inscripciones y clases comparten periodo y materia, sin
// repeticiones; periodo y materia pertenecen a ambas FKs.

pub const presencia = zigma.record(type_defs, zigma.merge(.{
    zigma.extractPk(inscripciones),
    zigma.extractPk(clases),
}));

pub const presencias = zigma.defineEntity(.{
    .pk = zigma.mergePk(.{ inscripciones.pk, clases.pk }),
    .fks = .{
        .inscripciones = .{ .entity = "inscripciones", .fields = inscripciones.pk },
        .clases = .{ .entity = "clases", .fields = clases.pk },
    },
    .fields = presencia,
});

// Dos FKs a la misma entidad, con campos renombrados.

pub const mesa = zigma.record(type_defs, zigma.merge(.{ zigma.extractPk(cursos), .{
    .fecha = .{ .type = "fecha" },
    .presidente = .{ .type = "text" },
    .vocal = .{ .type = "text" },
} }));

pub const mesas = zigma.defineEntity(.{
    .pk = zigma.mergePk(.{ cursos.pk, .{"fecha"} }),
    .fks = .{
        .cursos = .{ .entity = "cursos", .fields = cursos.pk },
        .presidente = .{ .entity = "docentes", .fields = .{ .presidente = "docente" } },
        .vocal = .{ .entity = "docentes", .fields = .{ .vocal = "docente" } },
    },
    .fields = mesa,
});

pub const record_defs = .{
    .cargo = cargo,
    .docente = docente,
    .materia = materia,
    .asignacion = asignacion,
    .periodo = periodo,
    .curso = curso,
    .clase = clase,
    .alumno = alumno,
    .pregunta = pregunta,
    .opcion = opcion,
    .inscripcion = inscripcion,
    .presencia = presencia,
    .mesa = mesa,
};

/// Función de negocio con tipado estricto: el parámetro tiene el tipo concreto
/// de instancia derivado de la definición, no anytype. Un literal anónimo se
/// convierte implícitamente y se comprueba en el punto de llamada. Dar un tipo
/// concreto a un valor de runtime (por ejemplo, JSON parseado) corresponde a una
/// función previa de parseo y validación, no a las funciones de negocio.
pub fn validarCargo(cargo_sin_validar: DefinedType(cargo)) error{AyudanteNoPuedeDirigir}!void {
    if (!(cargo_sin_validar.puede_dirigir orelse false)) return;
    const denomination = cargo_sin_validar.denominacion orelse return;
    if (std.ascii.findIgnoreCase(denomination, "ayudante") != null) {
        return error.AyudanteNoPuedeDirigir;
    }
}

/// Acá se representan solo los campos que intervienen en la regla de negocio de docente.
/// Son opcionales porque los metadatos actuales de la base permiten null en ambas
/// columnas. Un cargo null no activa la regla; un docente teórico debe tener un
/// valor de experiencia conocido y de al menos cinco años.
pub const DocenteBusinessState = struct {
    cargo: ?[]const u8,
    experiencia: ?i64,
};

pub const DocenteValidationError = error{TeoricoRequiereCincoAniosExperiencia};

pub fn validarDocente(value: DocenteBusinessState) DocenteValidationError!void {
    const cargo_value = value.cargo orelse return;
    const normalized_cargo = std.mem.trim(u8, cargo_value, " \t\r\n");
    if (!std.ascii.eqlIgnoreCase(normalized_cargo, "teorico")) return;

    const experiencia = value.experiencia orelse
        return error.TeoricoRequiereCincoAniosExperiencia;
    if (experiencia < 5)
        return error.TeoricoRequiereCincoAniosExperiencia;
}

pub const entity_defs = zigma.defineEntities(.{
    .docentes = docentes,
    .materias = materias,
    .periodos = periodos,
    .cursos = cursos,
    .clases = clases,
    .alumnos = alumnos,
    .preguntas = preguntas,
    .opciones = opciones,
    .inscripciones = inscripciones,
    .presencias = presencias,
    .mesas = mesas,
});

/// Modelo normalizado compartido por REST, PostgreSQL y los tipos de aplicación.
pub const Model = zigma.System(type_defs, entity_defs);
