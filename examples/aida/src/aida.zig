//! EJEMPLO: el sistema de alumnos (el mismo ejemplo aida de system-design).

const std = @import("std");
const zigma = @import("zigma");

pub const Fecha = struct { @"año": u16, mes: u8, @"día": u8 };

pub const type_defs = zigma.defineTypes(zigma.merge(.{ zigma.common_type_defs, .{
    .fecha = zigma.TypeDef{ .Type = Fecha },
    .email = zigma.common_type_defs.text,
} }));

pub const cargo = zigma.record(type_defs, .{
    .cargo = .{ .type = "text" },
    .denominacion = .{ .type = "text", .label = "denominación" },
    .orden = .{ .type = "integer" },
    .puede_dirigir = .{ .type = "boolean" },
});

pub const Cargo = zigma.RecordInstanceType(type_defs, cargo);

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
    .esImportador = .{ .type = "boolean" },
});

pub const asignacion = zigma.record(type_defs, .{
    .docente = docente.docente,
    .materia = materia.materia,
    .cargo = cargo.cargo,
});

pub const periodo = zigma.record(type_defs, .{
    .periodo = .{ .type = "text", .description = "bimestre, cuatrimestre, etc..." },
});

// Definiciones de entidad: agregan claves y relaciones a los records.
// Los tipos concretos y su registro se componen al final del contrato.

pub const docente_def = .{
    .pk = .{"docente"},
    // FK reflexiva: dentro de su definición, la entidad se referencia por nombre
    // y el campo origen (jefe) se asocia al campo destino (docente).
    .fks = .{ .jefe = .{ .entity = "docentes", .fields = .{ .jefe = "docente" } } },
    .fields = docente,
};
pub const materia_def = .{
    .pk = .{"materia"},
    .uks = .{ .denominacion = .{"denominacion"} },
    .fields = materia,
};
pub const periodo_def = .{ .pk = .{"periodo"}, .fields = periodo };

pub const curso = zigma.record(type_defs, zigma.merge(.{
    zigma.extractPk(periodo_def),
    zigma.extractPk(materia_def),
    zigma.extractPk(docente_def), // docente responsable del curso
}));

pub const curso_def = .{
    .pk = .{ "periodo", "materia" },
    .fks = .{
        .periodos = .{ .entity = "periodos", .fields = periodo_def.pk },
        .materias = .{ .entity = "materias", .fields = materia_def.pk },
        .responsable = .{ .entity = "docentes", .fields = docente_def.pk },
    },
    .fields = curso,
};

pub const clase = zigma.record(type_defs, zigma.merge(.{ zigma.extractPk(curso_def), .{
    .orden = .{ .type = "integer" },
    .fecha = .{ .type = "fecha" },
    .tema = .{ .type = "text" },
} }));

pub const clase_def = .{
    .pk = zigma.mergePk(.{ curso_def.pk, .{"orden"} }),
    .fks = .{ .cursos = .{ .entity = "cursos", .fields = curso_def.pk } },
    .fields = clase,
};

pub const alumno = zigma.record(type_defs, .{
    .alumno = .{ .type = "text" },
    .apellido = .{ .type = "text", .nullable = false },
    .nombres = .{ .type = "text", .nullable = false },
    .email = .{ .type = "email" },
});

pub const alumno_def = .{ .pk = .{"alumno"}, .fields = alumno };

pub const pregunta = zigma.record(type_defs, zigma.merge(.{ zigma.extractPk(clase_def), .{
    .pregunta = .{ .type = "integer" },
    .formulacion = .{ .type = "text", .nullable = false, .label = "formulación", .description = "texto principal de la pregunta" },
    .aclaraciones = .{ .type = "text", .description = "texto que no necesita repetirse cuando se quiera referir a una pregunta por su formulación, pero que es necesario para aclarar el contexto o posibles ambigüedades de la pregunta" },
    .tipo_respuesta = .{ .type = "text", .nullable = false, .label = "tipo" },
} }));

pub const pregunta_def = .{
    .pk = zigma.mergePk(.{ clase_def.pk, .{"pregunta"} }),
    .fks = .{ .clases = .{ .entity = "clases", .fields = clase_def.pk } },
    .fields = pregunta,
};

pub const opcion = zigma.record(type_defs, zigma.merge(.{ zigma.extractPk(pregunta_def), .{
    .opcion = .{ .type = "text" },
    .detalle = .{ .type = "text" },
} }));

pub const opcion_def = .{
    .pk = zigma.mergePk(.{ pregunta_def.pk, .{"opcion"} }),
    .fks = .{ .preguntas = .{ .entity = "preguntas", .fields = pregunta_def.pk } },
    .fields = opcion,
};

pub const inscripcion = zigma.record(type_defs, zigma.merge(.{
    zigma.extractPk(curso_def),
    zigma.extractPk(alumno_def),
}));

pub const inscripcion_def = .{
    .pk = zigma.mergePk(.{ curso_def.pk, .{"alumno"} }),
    .fks = .{
        .cursos = .{ .entity = "cursos", .fields = curso_def.pk },
        .alumnos = .{ .entity = "alumnos", .fields = alumno_def.pk },
    },
    .fields = inscripcion,
};

// PK combinada: inscripciones y clases comparten periodo y materia, sin
// repeticiones; periodo y materia pertenecen a ambas FKs.

pub const presencia = zigma.record(type_defs, zigma.merge(.{
    zigma.extractPk(inscripcion_def),
    zigma.extractPk(clase_def),
}));

pub const presencia_def = .{
    .pk = zigma.mergePk(.{ inscripcion_def.pk, clase_def.pk }),
    .fks = .{
        .inscripciones = .{ .entity = "inscripciones", .fields = inscripcion_def.pk },
        .clases = .{ .entity = "clases", .fields = clase_def.pk },
    },
    .fields = presencia,
};

// Dos FKs a la misma entidad, con campos renombrados.

pub const mesa = zigma.record(type_defs, zigma.merge(.{ zigma.extractPk(curso_def), .{
    .fecha = .{ .type = "fecha" },
    .presidente = .{ .type = "text" },
    .vocal = .{ .type = "text" },
} }));

pub const mesa_def = .{
    .pk = zigma.mergePk(.{ curso_def.pk, .{"fecha"} }),
    .fks = .{
        .cursos = .{ .entity = "cursos", .fields = curso_def.pk },
        .presidente = .{ .entity = "docentes", .fields = .{ .presidente = "docente" } },
        .vocal = .{ .entity = "docentes", .fields = .{ .vocal = "docente" } },
    },
    .fields = mesa,
};

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
/// de instancia derivado de la definición, no anytype.
pub fn validarCargo(cargo_sin_validar: Cargo) error{AyudanteNoPuedeDirigir}!void {
    if (!(cargo_sin_validar.puede_dirigir orelse false)) return;
    const denomination = cargo_sin_validar.denominacion orelse return;
    if (std.ascii.findIgnoreCase(denomination, "ayudante") != null) {
        return error.AyudanteNoPuedeDirigir;
    }
}

pub const DocenteValidationError = error{TeoricoRequiereCincoAniosExperiencia};

/// La entidad concreta lleva todos los campos; la regla usa cargo y experiencia.
pub fn validarDocente(doc: Docente) DocenteValidationError!void {
    const cargo_value = doc.cargo orelse return;
    const normalized_cargo = std.mem.trim(u8, cargo_value, " \t\r\n");
    if (!std.ascii.eqlIgnoreCase(normalized_cargo, "teorico")) return;

    const experiencia = doc.experiencia orelse
        return error.TeoricoRequiereCincoAniosExperiencia;
    if (experiencia < 5)
        return error.TeoricoRequiereCincoAniosExperiencia;
}

/// Tipos concretos de aplicación; sus campos se generan desde las definiciones.
pub const Docente = zigma.Entity(type_defs, docente_def);
pub const Materia = zigma.Entity(type_defs, materia_def);
pub const Periodo = zigma.Entity(type_defs, periodo_def);
pub const Curso = zigma.Entity(type_defs, curso_def);
pub const Clase = zigma.Entity(type_defs, clase_def);
pub const Alumno = zigma.Entity(type_defs, alumno_def);
pub const Pregunta = zigma.Entity(type_defs, pregunta_def);
pub const Opcion = zigma.Entity(type_defs, opcion_def);
pub const Inscripcion = zigma.Entity(type_defs, inscripcion_def);
pub const Presencia = zigma.Entity(type_defs, presencia_def);
pub const Mesa = zigma.Entity(type_defs, mesa_def);

/// Nombres de tablas y rutas asociados a cada tipo y su definición descriptiva.
pub const entity_defs = zigma.defineEntities(.{
    .docentes = .{ .Type = Docente, .definition = docente_def },
    .materias = .{ .Type = Materia, .definition = materia_def },
    .periodos = .{ .Type = Periodo, .definition = periodo_def },
    .cursos = .{ .Type = Curso, .definition = curso_def },
    .clases = .{ .Type = Clase, .definition = clase_def },
    .alumnos = .{ .Type = Alumno, .definition = alumno_def },
    .preguntas = .{ .Type = Pregunta, .definition = pregunta_def },
    .opciones = .{ .Type = Opcion, .definition = opcion_def },
    .inscripciones = .{ .Type = Inscripcion, .definition = inscripcion_def },
    .presencias = .{ .Type = Presencia, .definition = presencia_def },
    .mesas = .{ .Type = Mesa, .definition = mesa_def },
});

/// Modelo normalizado compartido por REST, PostgreSQL y los tipos de aplicación.
pub const Model = zigma.Framework(type_defs, entity_defs);
