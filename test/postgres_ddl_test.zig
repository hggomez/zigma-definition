const std = @import("std");
const zigma = @import("zigma");
const postgres_ddl = @import("zigma_postgres_ddl");
const aida = @import("aida");

const expectEqualStrings = std.testing.expectEqualStrings;

const type_mappings = postgres_ddl.defineTypeMappings(zigma.merge(.{
    postgres_ddl.common_type_mappings,
    .{
        .fecha = postgres_ddl.TypeMapping{ .sql_type = "DATE" },
        .email = postgres_ddl.TypeMapping{ .sql_type = "TEXT" },
    },
}));

const quoted_fields = zigma.record(aida.type_defs, .{
    .@"quoted\"field" = .{ .type = "text" },
});
const quoted_entity = zigma.defineEntity(.{
    .pk = .{"quoted\"field"},
    .fields = quoted_fields,
});
const quoted_entity_defs = zigma.defineEntities(.{
    .@"quoted\"table" = quoted_entity,
});

const base_fields = zigma.record(aida.type_defs, .{
    .thing = .{ .type = "text" },
});
const extended_fields = zigma.record(aida.type_defs, zigma.merge(.{ base_fields, .{
    .created_on = .{ .type = "fecha", .nullable = false },
} }));
const extended_entity = zigma.defineEntity(.{
    .pk = .{"thing"},
    .fields = extended_fields,
});
const extended_entity_defs = zigma.defineEntities(.{ .things = extended_entity });

const parent_fields = zigma.record(aida.type_defs, .{
    .parent = .{ .type = "text" },
});
const parents = zigma.defineEntity(.{
    .pk = .{"parent"},
    .fields = parent_fields,
});
const child_fields = zigma.record(aida.type_defs, .{
    .child = .{ .type = "text" },
    .parent = .{ .type = "text" },
});
const children = zigma.defineEntity(.{
    .pk = .{"child"},
    .fks = .{ .parents = .{ .entity = "parents", .fields = parents.pk } },
    .fields = child_fields,
});
const reverse_dependency_defs = zigma.defineEntities(.{
    .children = children,
    .parents = parents,
});

test "defines PostgreSQL mappings separately from domain types" {
    try expectEqualStrings("TEXT", type_mappings.text.sql_type);
    try expectEqualStrings("BIGINT", type_mappings.integer.sql_type);
    try expectEqualStrings("BOOLEAN", type_mappings.boolean.sql_type);
    try expectEqualStrings("DATE", type_mappings.fecha.sql_type);
    try expectEqualStrings("TEXT", type_mappings.email.sql_type);
}

test "creates a table with nullability, pk and uk" {
    const actual = postgres_ddl.createTableDdl(aida.entity_defs, "materias", type_mappings);
    const expected =
        \\CREATE TABLE IF NOT EXISTS "materias" (
        \\    "materia" TEXT NOT NULL,
        \\    "denominacion" TEXT NOT NULL,
        \\    CONSTRAINT "pk_materias" PRIMARY KEY ("materia"),
        \\    CONSTRAINT "uk_materias_denominacion" UNIQUE ("denominacion")
        \\);
        \\
    ;
    try expectEqualStrings(expected, actual);
}

test "creates composite and renamed foreign keys with stable names" {
    const actual = postgres_ddl.createTableDdl(aida.entity_defs, "mesas", type_mappings);
    const expected =
        \\CREATE TABLE IF NOT EXISTS "mesas" (
        \\    "periodo" TEXT NOT NULL,
        \\    "materia" TEXT NOT NULL,
        \\    "fecha" DATE NOT NULL,
        \\    "presidente" TEXT,
        \\    "vocal" TEXT,
        \\    CONSTRAINT "pk_mesas" PRIMARY KEY ("periodo", "materia", "fecha"),
        \\    CONSTRAINT "fk_mesas_cursos" FOREIGN KEY ("periodo", "materia") REFERENCES "cursos" ("periodo", "materia"),
        \\    CONSTRAINT "fk_mesas_presidente" FOREIGN KEY ("presidente") REFERENCES "docentes" ("docente"),
        \\    CONSTRAINT "fk_mesas_vocal" FOREIGN KEY ("vocal") REFERENCES "docentes" ("docente")
        \\);
        \\
    ;
    try expectEqualStrings(expected, actual);
}

test "creates a reflexive foreign key inline" {
    const actual = postgres_ddl.createTableDdl(aida.entity_defs, "docentes", type_mappings);
    const expected =
        \\CREATE TABLE IF NOT EXISTS "docentes" (
        \\    "docente" TEXT NOT NULL,
        \\    "apellido" TEXT,
        \\    "nombres" TEXT NOT NULL,
        \\    "cargo" TEXT,
        \\    "email" TEXT,
        \\    "email_alternativo" TEXT,
        \\    "jefe" TEXT,
        \\    CONSTRAINT "pk_docentes" PRIMARY KEY ("docente"),
        \\    CONSTRAINT "fk_docentes_jefe" FOREIGN KEY ("jefe") REFERENCES "docentes" ("docente")
        \\);
        \\
    ;
    try expectEqualStrings(expected, actual);
}

test "escapes PostgreSQL identifiers" {
    const actual = postgres_ddl.createTableDdl(quoted_entity_defs, "quoted\"table", type_mappings);
    const expected =
        \\CREATE TABLE IF NOT EXISTS "quoted""table" (
        \\    "quoted""field" TEXT NOT NULL,
        \\    CONSTRAINT "pk_quoted""table" PRIMARY KEY ("quoted""field")
        \\);
        \\
    ;
    try expectEqualStrings(expected, actual);
}

test "adding a field only changes the complete create table statement" {
    const actual = postgres_ddl.createTableDdl(extended_entity_defs, "things", type_mappings);
    const expected =
        \\CREATE TABLE IF NOT EXISTS "things" (
        \\    "thing" TEXT NOT NULL,
        \\    "created_on" DATE NOT NULL,
        \\    CONSTRAINT "pk_things" PRIMARY KEY ("thing")
        \\);
        \\
    ;
    try expectEqualStrings(expected, actual);
    try std.testing.expect(std.mem.indexOf(u8, actual, "ALTER TABLE") == null);
}

test "places referenced tables before dependants regardless of declaration order" {
    const actual = postgres_ddl.createSchemaDdl(reverse_dependency_defs, type_mappings);
    const expected =
        \\CREATE TABLE IF NOT EXISTS "parents" (
        \\    "parent" TEXT NOT NULL,
        \\    CONSTRAINT "pk_parents" PRIMARY KEY ("parent")
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS "children" (
        \\    "child" TEXT NOT NULL,
        \\    "parent" TEXT,
        \\    CONSTRAINT "pk_children" PRIMARY KEY ("child"),
        \\    CONSTRAINT "fk_children_parents" FOREIGN KEY ("parent") REFERENCES "parents" ("parent")
        \\);
        \\
    ;
    try expectEqualStrings(expected, actual);
}

test "creates the complete AIDA schema in dependency order" {
    const actual = postgres_ddl.createSchemaDdl(aida.entity_defs, type_mappings);
    const expected =
        \\CREATE TABLE IF NOT EXISTS "docentes" (
        \\    "docente" TEXT NOT NULL,
        \\    "apellido" TEXT,
        \\    "nombres" TEXT NOT NULL,
        \\    "cargo" TEXT,
        \\    "email" TEXT,
        \\    "email_alternativo" TEXT,
        \\    "jefe" TEXT,
        \\    CONSTRAINT "pk_docentes" PRIMARY KEY ("docente"),
        \\    CONSTRAINT "fk_docentes_jefe" FOREIGN KEY ("jefe") REFERENCES "docentes" ("docente")
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS "materias" (
        \\    "materia" TEXT NOT NULL,
        \\    "denominacion" TEXT NOT NULL,
        \\    CONSTRAINT "pk_materias" PRIMARY KEY ("materia"),
        \\    CONSTRAINT "uk_materias_denominacion" UNIQUE ("denominacion")
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS "periodos" (
        \\    "periodo" TEXT NOT NULL,
        \\    CONSTRAINT "pk_periodos" PRIMARY KEY ("periodo")
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS "cursos" (
        \\    "periodo" TEXT NOT NULL,
        \\    "materia" TEXT NOT NULL,
        \\    "docente" TEXT,
        \\    CONSTRAINT "pk_cursos" PRIMARY KEY ("periodo", "materia"),
        \\    CONSTRAINT "fk_cursos_periodos" FOREIGN KEY ("periodo") REFERENCES "periodos" ("periodo"),
        \\    CONSTRAINT "fk_cursos_materias" FOREIGN KEY ("materia") REFERENCES "materias" ("materia"),
        \\    CONSTRAINT "fk_cursos_responsable" FOREIGN KEY ("docente") REFERENCES "docentes" ("docente")
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS "clases" (
        \\    "periodo" TEXT NOT NULL,
        \\    "materia" TEXT NOT NULL,
        \\    "orden" BIGINT NOT NULL,
        \\    "fecha" DATE,
        \\    "tema" TEXT,
        \\    CONSTRAINT "pk_clases" PRIMARY KEY ("periodo", "materia", "orden"),
        \\    CONSTRAINT "fk_clases_cursos" FOREIGN KEY ("periodo", "materia") REFERENCES "cursos" ("periodo", "materia")
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS "alumnos" (
        \\    "alumno" TEXT NOT NULL,
        \\    "apellido" TEXT NOT NULL,
        \\    "nombres" TEXT NOT NULL,
        \\    "email" TEXT,
        \\    CONSTRAINT "pk_alumnos" PRIMARY KEY ("alumno")
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS "preguntas" (
        \\    "periodo" TEXT NOT NULL,
        \\    "materia" TEXT NOT NULL,
        \\    "orden" BIGINT NOT NULL,
        \\    "pregunta" BIGINT NOT NULL,
        \\    "formulacion" TEXT NOT NULL,
        \\    "aclaraciones" TEXT,
        \\    "tipo_respuesta" TEXT NOT NULL,
        \\    CONSTRAINT "pk_preguntas" PRIMARY KEY ("periodo", "materia", "orden", "pregunta"),
        \\    CONSTRAINT "fk_preguntas_clases" FOREIGN KEY ("periodo", "materia", "orden") REFERENCES "clases" ("periodo", "materia", "orden")
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS "opciones" (
        \\    "periodo" TEXT NOT NULL,
        \\    "materia" TEXT NOT NULL,
        \\    "orden" BIGINT NOT NULL,
        \\    "pregunta" BIGINT NOT NULL,
        \\    "opcion" TEXT NOT NULL,
        \\    "detalle" TEXT,
        \\    CONSTRAINT "pk_opciones" PRIMARY KEY ("periodo", "materia", "orden", "pregunta", "opcion"),
        \\    CONSTRAINT "fk_opciones_preguntas" FOREIGN KEY ("periodo", "materia", "orden", "pregunta") REFERENCES "preguntas" ("periodo", "materia", "orden", "pregunta")
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS "inscripciones" (
        \\    "periodo" TEXT NOT NULL,
        \\    "materia" TEXT NOT NULL,
        \\    "alumno" TEXT NOT NULL,
        \\    CONSTRAINT "pk_inscripciones" PRIMARY KEY ("periodo", "materia", "alumno"),
        \\    CONSTRAINT "fk_inscripciones_cursos" FOREIGN KEY ("periodo", "materia") REFERENCES "cursos" ("periodo", "materia"),
        \\    CONSTRAINT "fk_inscripciones_alumnos" FOREIGN KEY ("alumno") REFERENCES "alumnos" ("alumno")
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS "presencias" (
        \\    "periodo" TEXT NOT NULL,
        \\    "materia" TEXT NOT NULL,
        \\    "alumno" TEXT NOT NULL,
        \\    "orden" BIGINT NOT NULL,
        \\    CONSTRAINT "pk_presencias" PRIMARY KEY ("periodo", "materia", "alumno", "orden"),
        \\    CONSTRAINT "fk_presencias_inscripciones" FOREIGN KEY ("periodo", "materia", "alumno") REFERENCES "inscripciones" ("periodo", "materia", "alumno"),
        \\    CONSTRAINT "fk_presencias_clases" FOREIGN KEY ("periodo", "materia", "orden") REFERENCES "clases" ("periodo", "materia", "orden")
        \\);
        \\
        \\CREATE TABLE IF NOT EXISTS "mesas" (
        \\    "periodo" TEXT NOT NULL,
        \\    "materia" TEXT NOT NULL,
        \\    "fecha" DATE NOT NULL,
        \\    "presidente" TEXT,
        \\    "vocal" TEXT,
        \\    CONSTRAINT "pk_mesas" PRIMARY KEY ("periodo", "materia", "fecha"),
        \\    CONSTRAINT "fk_mesas_cursos" FOREIGN KEY ("periodo", "materia") REFERENCES "cursos" ("periodo", "materia"),
        \\    CONSTRAINT "fk_mesas_presidente" FOREIGN KEY ("presidente") REFERENCES "docentes" ("docente"),
        \\    CONSTRAINT "fk_mesas_vocal" FOREIGN KEY ("vocal") REFERENCES "docentes" ("docente")
        \\);
        \\
    ;
    try expectEqualStrings(expected, actual);
}
