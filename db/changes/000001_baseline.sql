--liquibase formatted sql
--changeset zigma:000001_baseline
--comment: initial schema generated from the Zigma desired state

CREATE TABLE "docentes" (
    "docente" TEXT NOT NULL,
    "apellido" TEXT,
    "nombres" TEXT NOT NULL,
    "cargo" TEXT,
    "email" TEXT,
    "email_alternativo" TEXT,
    "jefe" TEXT,
    CONSTRAINT "pk_docentes" PRIMARY KEY ("docente"),
    CONSTRAINT "fk_docentes_jefe" FOREIGN KEY ("jefe") REFERENCES "docentes" ("docente")
);

CREATE TABLE "materias" (
    "materia" TEXT NOT NULL,
    "denominacion" TEXT NOT NULL,
    CONSTRAINT "pk_materias" PRIMARY KEY ("materia"),
    CONSTRAINT "uk_materias_denominacion" UNIQUE ("denominacion")
);

CREATE TABLE "periodos" (
    "periodo" TEXT NOT NULL,
    CONSTRAINT "pk_periodos" PRIMARY KEY ("periodo")
);

CREATE TABLE "cursos" (
    "periodo" TEXT NOT NULL,
    "materia" TEXT NOT NULL,
    "docente" TEXT,
    CONSTRAINT "pk_cursos" PRIMARY KEY ("periodo", "materia"),
    CONSTRAINT "fk_cursos_periodos" FOREIGN KEY ("periodo") REFERENCES "periodos" ("periodo"),
    CONSTRAINT "fk_cursos_materias" FOREIGN KEY ("materia") REFERENCES "materias" ("materia"),
    CONSTRAINT "fk_cursos_responsable" FOREIGN KEY ("docente") REFERENCES "docentes" ("docente")
);

CREATE TABLE "clases" (
    "periodo" TEXT NOT NULL,
    "materia" TEXT NOT NULL,
    "orden" BIGINT NOT NULL,
    "fecha" DATE,
    "tema" TEXT,
    CONSTRAINT "pk_clases" PRIMARY KEY ("periodo", "materia", "orden"),
    CONSTRAINT "fk_clases_cursos" FOREIGN KEY ("periodo", "materia") REFERENCES "cursos" ("periodo", "materia")
);

CREATE TABLE "alumnos" (
    "alumno" TEXT NOT NULL,
    "apellido" TEXT NOT NULL,
    "nombres" TEXT NOT NULL,
    "email" TEXT,
    CONSTRAINT "pk_alumnos" PRIMARY KEY ("alumno")
);

CREATE TABLE "preguntas" (
    "periodo" TEXT NOT NULL,
    "materia" TEXT NOT NULL,
    "orden" BIGINT NOT NULL,
    "pregunta" BIGINT NOT NULL,
    "formulacion" TEXT NOT NULL,
    "aclaraciones" TEXT,
    "tipo_respuesta" TEXT NOT NULL,
    CONSTRAINT "pk_preguntas" PRIMARY KEY ("periodo", "materia", "orden", "pregunta"),
    CONSTRAINT "fk_preguntas_clases" FOREIGN KEY ("periodo", "materia", "orden") REFERENCES "clases" ("periodo", "materia", "orden")
);

CREATE TABLE "opciones" (
    "periodo" TEXT NOT NULL,
    "materia" TEXT NOT NULL,
    "orden" BIGINT NOT NULL,
    "pregunta" BIGINT NOT NULL,
    "opcion" TEXT NOT NULL,
    "detalle" TEXT,
    CONSTRAINT "pk_opciones" PRIMARY KEY ("periodo", "materia", "orden", "pregunta", "opcion"),
    CONSTRAINT "fk_opciones_preguntas" FOREIGN KEY ("periodo", "materia", "orden", "pregunta") REFERENCES "preguntas" ("periodo", "materia", "orden", "pregunta")
);

CREATE TABLE "inscripciones" (
    "periodo" TEXT NOT NULL,
    "materia" TEXT NOT NULL,
    "alumno" TEXT NOT NULL,
    CONSTRAINT "pk_inscripciones" PRIMARY KEY ("periodo", "materia", "alumno"),
    CONSTRAINT "fk_inscripciones_cursos" FOREIGN KEY ("periodo", "materia") REFERENCES "cursos" ("periodo", "materia"),
    CONSTRAINT "fk_inscripciones_alumnos" FOREIGN KEY ("alumno") REFERENCES "alumnos" ("alumno")
);

CREATE TABLE "presencias" (
    "periodo" TEXT NOT NULL,
    "materia" TEXT NOT NULL,
    "alumno" TEXT NOT NULL,
    "orden" BIGINT NOT NULL,
    CONSTRAINT "pk_presencias" PRIMARY KEY ("periodo", "materia", "alumno", "orden"),
    CONSTRAINT "fk_presencias_inscripciones" FOREIGN KEY ("periodo", "materia", "alumno") REFERENCES "inscripciones" ("periodo", "materia", "alumno"),
    CONSTRAINT "fk_presencias_clases" FOREIGN KEY ("periodo", "materia", "orden") REFERENCES "clases" ("periodo", "materia", "orden")
);

CREATE TABLE "mesas" (
    "periodo" TEXT NOT NULL,
    "materia" TEXT NOT NULL,
    "fecha" DATE NOT NULL,
    "presidente" TEXT,
    "vocal" TEXT,
    CONSTRAINT "pk_mesas" PRIMARY KEY ("periodo", "materia", "fecha"),
    CONSTRAINT "fk_mesas_cursos" FOREIGN KEY ("periodo", "materia") REFERENCES "cursos" ("periodo", "materia"),
    CONSTRAINT "fk_mesas_presidente" FOREIGN KEY ("presidente") REFERENCES "docentes" ("docente"),
    CONSTRAINT "fk_mesas_vocal" FOREIGN KEY ("vocal") REFERENCES "docentes" ("docente")
);
