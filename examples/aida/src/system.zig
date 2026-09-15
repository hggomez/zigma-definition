//! Injected `system` for generators: aida Defs plus optional demo seeds.
//! Generators require `type_defs` and `entity_defs`; `seeds` is optional.

const aida = @import("aida.zig");

pub const type_defs = aida.type_defs;
pub const entity_defs = aida.entity_defs;

pub const seeds = .{
    .periodos = [_]aida.DefinedType(aida.periodo){
        .{ .periodo = "1C2024" },
        .{ .periodo = "2C2024" },
    },
    .materias = [_]aida.DefinedType(aida.materia){
        .{ .materia = "AlgoI", .denominacion = "Algoritmos y Programacion I" },
        .{ .materia = "AlgoII", .denominacion = "Algoritmos y Programacion II" },
        .{ .materia = "BD", .denominacion = "Bases de Datos" },
    },
    .docentes = [_]aida.DefinedType(aida.docente){
        .{
            .docente = "1",
            .apellido = "Perez",
            .nombres = "Ana",
            .cargo = "TIT",
            .email = "ana@example.com",
            .email_alternativo = "",
            .jefe = "",
        },
        .{
            .docente = "2",
            .apellido = "Gomez",
            .nombres = "Luis",
            .cargo = "JTP",
            .email = "luis@example.com",
            .email_alternativo = "",
            .jefe = "1",
        },
    },
    .alumnos = [_]aida.DefinedType(aida.alumno){
        .{ .alumno = "123", .apellido = "Garcia", .nombres = "Maria", .email = "maria@example.com" },
        .{ .alumno = "456", .apellido = "Lopez", .nombres = "Juan", .email = "juan@example.com" },
    },
    .cursos = [_]aida.DefinedType(aida.curso){
        .{ .periodo = "1C2024", .materia = "AlgoI", .docente = "1" },
        .{ .periodo = "2C2024", .materia = "AlgoII", .docente = "2" },
    },
    .clases = [_]aida.DefinedType(aida.clase){
        .{
            .periodo = "1C2024",
            .materia = "AlgoI",
            .orden = 1,
            .fecha = .{ .@"año" = 2024, .mes = 3, .@"día" = 15 },
            .tema = "intro",
        },
        .{
            .periodo = "1C2024",
            .materia = "AlgoI",
            .orden = 2,
            .fecha = .{ .@"año" = 2024, .mes = 3, .@"día" = 22 },
            .tema = "recursion",
        },
    },
    .preguntas = [_]aida.DefinedType(aida.pregunta){
        .{
            .periodo = "1C2024",
            .materia = "AlgoI",
            .orden = 1,
            .pregunta = 1,
            .formulacion = "Que es un algoritmo?",
            .aclaraciones = "",
            .tipo_respuesta = "opcion multiple",
        },
        .{
            .periodo = "1C2024",
            .materia = "AlgoI",
            .orden = 1,
            .pregunta = 2,
            .formulacion = "Escribir un ejemplo",
            .aclaraciones = "en pseudocodigo",
            .tipo_respuesta = "texto",
        },
    },
    .opciones = [_]aida.DefinedType(aida.opcion){
        .{
            .periodo = "1C2024",
            .materia = "AlgoI",
            .orden = 1,
            .pregunta = 1,
            .opcion = "A",
            .detalle = "Una secuencia de pasos",
        },
        .{
            .periodo = "1C2024",
            .materia = "AlgoI",
            .orden = 1,
            .pregunta = 1,
            .opcion = "B",
            .detalle = "Un lenguaje de programacion",
        },
    },
    .inscripciones = [_]aida.DefinedType(aida.inscripcion){
        .{ .periodo = "1C2024", .materia = "AlgoI", .alumno = "123" },
        .{ .periodo = "1C2024", .materia = "AlgoI", .alumno = "456" },
    },
    .presencias = [_]aida.DefinedType(aida.presencia){
        .{ .periodo = "1C2024", .materia = "AlgoI", .alumno = "123", .orden = 1 },
        .{ .periodo = "1C2024", .materia = "AlgoI", .alumno = "456", .orden = 1 },
    },
    .mesas = [_]aida.DefinedType(aida.mesa){
        .{
            .periodo = "1C2024",
            .materia = "AlgoI",
            .fecha = .{ .@"año" = 2024, .mes = 7, .@"día" = 8 },
            .presidente = "1",
            .vocal = "2",
        },
        .{
            .periodo = "2C2024",
            .materia = "AlgoII",
            .fecha = .{ .@"año" = 2024, .mes = 12, .@"día" = 2 },
            .presidente = "2",
            .vocal = "1",
        },
    },
};
