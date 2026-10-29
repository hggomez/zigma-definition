-- The fake rows of the example stack (`zig build example`): obviously fake
-- values (`docente-1`, `materia-1`, ...), three per entity, parents first
-- (fks). Loaded on a freshly reset database, after the generated schema.
-- test/example_stack_test.zig checks that exactly these rows are listed.
--
-- Edge cases worth looking at in the frontend: docente-2 and docente-3 have
-- docente-1 as `jefe` (the reflexive fk); a clase without `fecha`; an `orden`
-- of 2^53 + 1 (not a JS number); nullable fields left empty.

INSERT INTO docentes (docente, apellido, nombres, cargo, email, email_alternativo, jefe) VALUES
  ('docente-1', 'apellido-1', 'nombres-1', 'cargo-1', 'docente-1@example.com', 'docente-1@example.org', NULL),
  ('docente-2', 'apellido-2', 'nombres-2', 'cargo-2', NULL, NULL, 'docente-1'),
  ('docente-3', 'apellido-3', 'nombres-3', NULL, NULL, NULL, 'docente-1');

INSERT INTO materias (materia, denominacion) VALUES
  ('materia-1', 'denominacion-1'),
  ('materia-2', 'denominacion-2'),
  ('materia-3', 'denominacion-3');

INSERT INTO periodos (periodo) VALUES
  ('periodo-1'),
  ('periodo-2'),
  ('periodo-3');

INSERT INTO cursos (periodo, materia, docente) VALUES
  ('periodo-1', 'materia-1', 'docente-1'),
  ('periodo-1', 'materia-2', 'docente-2'),
  ('periodo-2', 'materia-1', NULL);

INSERT INTO clases (periodo, materia, orden, fecha, tema) VALUES
  ('periodo-1', 'materia-1', 1, ROW(2026, 3, 14), 'tema-1'),
  ('periodo-1', 'materia-1', 2, NULL, 'tema-2'),
  ('periodo-1', 'materia-2', 9007199254740993, ROW(2026, 4, 1), NULL);

INSERT INTO alumnos (alumno, apellido, nombres, email) VALUES
  ('alumno-1', 'apellido-1', 'nombres-1', 'alumno-1@example.com'),
  ('alumno-2', 'apellido-2', 'nombres-2', 'alumno-2@example.com'),
  ('alumno-3', 'apellido-3', 'nombres-3', NULL);

INSERT INTO preguntas (periodo, materia, orden, pregunta, formulacion, aclaraciones, tipo_respuesta) VALUES
  ('periodo-1', 'materia-1', 1, 1, 'formulacion-1', NULL, 'tipo_respuesta-1'),
  ('periodo-1', 'materia-1', 1, 2, 'formulacion-2', 'aclaraciones-2', 'tipo_respuesta-2'),
  ('periodo-1', 'materia-1', 2, 1, 'formulacion-3', NULL, 'tipo_respuesta-1');

INSERT INTO opciones (periodo, materia, orden, pregunta, opcion, detalle) VALUES
  ('periodo-1', 'materia-1', 1, 1, 'opcion-1', 'detalle-1'),
  ('periodo-1', 'materia-1', 1, 1, 'opcion-2', NULL),
  ('periodo-1', 'materia-1', 1, 2, 'opcion-1', NULL);

INSERT INTO inscripciones (periodo, materia, alumno) VALUES
  ('periodo-1', 'materia-1', 'alumno-1'),
  ('periodo-1', 'materia-1', 'alumno-2'),
  ('periodo-1', 'materia-2', 'alumno-1');

INSERT INTO presencias (periodo, materia, alumno, orden) VALUES
  ('periodo-1', 'materia-1', 'alumno-1', 1),
  ('periodo-1', 'materia-1', 'alumno-1', 2),
  ('periodo-1', 'materia-1', 'alumno-2', 1);

INSERT INTO mesas (periodo, materia, fecha, presidente, vocal) VALUES
  ('periodo-1', 'materia-1', ROW(2026, 7, 1), 'docente-1', 'docente-2'),
  ('periodo-1', 'materia-2', ROW(2026, 7, 2), 'docente-2', NULL),
  ('periodo-2', 'materia-1', ROW(2026, 12, 1), NULL, NULL);
