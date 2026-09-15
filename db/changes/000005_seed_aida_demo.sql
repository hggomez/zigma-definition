--liquibase formatted sql
--changeset zigma:000005_seed_aida_demo
--comment: demo rows mirrored from examples/aida/src/system.zig seeds

INSERT INTO "periodos" ("periodo") VALUES
    ('1C2024'),
    ('2C2024');

INSERT INTO "materias" ("materia", "denominacion") VALUES
    ('AlgoI', 'Algoritmos y Programacion I'),
    ('AlgoII', 'Algoritmos y Programacion II'),
    ('BD', 'Bases de Datos');

INSERT INTO "docentes" (
    "docente", "apellido", "nombres", "cargo", "email",
    "email_alternativo", "jefe", "telefono", "experiencia", "esImportador"
) VALUES
    ('1', 'Perez', 'Ana', 'TIT', 'ana@example.com', NULL, NULL, NULL, NULL, NULL),
    ('2', 'Gomez', 'Luis', 'JTP', 'luis@example.com', NULL, '1', NULL, NULL, NULL);

INSERT INTO "alumnos" ("alumno", "apellido", "nombres", "email") VALUES
    ('123', 'Garcia', 'Maria', 'maria@example.com'),
    ('456', 'Lopez', 'Juan', 'juan@example.com');

INSERT INTO "cursos" ("periodo", "materia", "docente") VALUES
    ('1C2024', 'AlgoI', '1'),
    ('2C2024', 'AlgoII', '2');

INSERT INTO "clases" ("periodo", "materia", "orden", "fecha", "tema") VALUES
    ('1C2024', 'AlgoI', 1, DATE '2024-03-15', 'intro'),
    ('1C2024', 'AlgoI', 2, DATE '2024-03-22', 'recursion');

INSERT INTO "preguntas" (
    "periodo", "materia", "orden", "pregunta", "formulacion", "aclaraciones", "tipo_respuesta"
) VALUES
    ('1C2024', 'AlgoI', 1, 1, 'Que es un algoritmo?', NULL, 'opcion multiple'),
    ('1C2024', 'AlgoI', 1, 2, 'Escribir un ejemplo', 'en pseudocodigo', 'texto');

INSERT INTO "opciones" ("periodo", "materia", "orden", "pregunta", "opcion", "detalle") VALUES
    ('1C2024', 'AlgoI', 1, 1, 'A', 'Una secuencia de pasos'),
    ('1C2024', 'AlgoI', 1, 1, 'B', 'Un lenguaje de programacion');

INSERT INTO "inscripciones" ("periodo", "materia", "alumno") VALUES
    ('1C2024', 'AlgoI', '123'),
    ('1C2024', 'AlgoI', '456');

INSERT INTO "presencias" ("periodo", "materia", "alumno", "orden") VALUES
    ('1C2024', 'AlgoI', '123', 1),
    ('1C2024', 'AlgoI', '456', 1);

INSERT INTO "mesas" ("periodo", "materia", "fecha", "presidente", "vocal") VALUES
    ('1C2024', 'AlgoI', DATE '2024-07-08', '1', '2'),
    ('2C2024', 'AlgoII', DATE '2024-12-02', '2', '1');
