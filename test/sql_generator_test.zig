//! Tests for DDL (CREATE TABLE) generation from zigma EntityInfo, driving the
//! implementation of `sql_generator.zig`. Fixtures reuse `aida` entities once they
//! exercise a pattern the vocabulary already has (composite pk, uk, fks);
//! ad-hoc fixtures are defined here only for the minimal base-format cases.

const std = @import("std");
const zigma = @import("zigma");
const aida = @import("aida");
const sql = @import("sql_generator");
const expectEqualStrings = std.testing.expectEqualStrings;

const minimal_sql_types = .{ .text = "TEXT" };

const cosa = zigma.defineEntity(.{
    .pk = .{"cosa"},
    .fields = zigma.record(zigma.common_type_defs, .{
        .cosa = .{ .type = "text" },
    }),
});

// A container-level const is always evaluated in comptime scope, so its
// value stays comptime-known even when read from the runtime test body
// below (see zigma.zig's PkMerge/LabelHolder for the same trick). The DDL
// call itself needs to happen here too, not inside the test body: calling a
// zigma-style comptime function from a runtime scope only yields a runtime
// copy of its result, which is not comptime-known enough for createTableSql
// to do `@field(sql_types, field.type)` internally.
const cosa_info = zigma.completeEntity(cosa);
const cosa_ddl = sql.createTableSql(minimal_sql_types, "cosa", cosa_info);

test "generates a CREATE TABLE with the entity's single column and its SQL type" {
    try expectEqualStrings(
        \\CREATE TABLE cosa (
        \\    cosa TEXT NOT NULL,
        \\    PRIMARY KEY (cosa)
        \\);
    , cosa_ddl);
}

const varias_sql_types = .{ .text = "TEXT", .integer = "INTEGER", .boolean = "BOOLEAN" };

const varias = zigma.defineEntity(.{
    .pk = .{"id"},
    .fields = zigma.record(zigma.common_type_defs, .{
        .id = .{ .type = "text" },
        .cantidad = .{ .type = "integer" },
        .activo = .{ .type = "boolean" },
    }),
});
const varias_info = zigma.completeEntity(varias);
const varias_ddl = sql.createTableSql(varias_sql_types, "varias", varias_info);

test "maps each field to the SQL type that corresponds to it, not just the first one" {
    try expectEqualStrings(
        \\CREATE TABLE varias (
        \\    id TEXT NOT NULL,
        \\    cantidad INTEGER,
        \\    activo BOOLEAN,
        \\    PRIMARY KEY (id)
        \\);
    , varias_ddl);
}

// cosa and varias are independent (no fk between them): fk clauses are a
// later step, this one only checks the multi-entity aggregation.
const dos_entidades = zigma.defineEntities(.{ .cosa = cosa, .varias = varias });
const dos_entidades_ddl = sql.schemaSql(varias_sql_types, dos_entidades);

test "schemaSql generates one CREATE TABLE per entity, in declaration order, for more than one entity" {
    try expectEqualStrings(
        \\CREATE TABLE cosa (
        \\    cosa TEXT NOT NULL,
        \\    PRIMARY KEY (cosa)
        \\);
        \\
        \\CREATE TABLE varias (
        \\    id TEXT NOT NULL,
        \\    cantidad INTEGER,
        \\    activo BOOLEAN,
        \\    PRIMARY KEY (id)
        \\);
    , dos_entidades_ddl);
}

// aida.fecha is backed by a nested struct (Fecha{ año, mes, día }), not a
// primitive; createTableSql never looks at the underlying Zig type (only at
// the domain type name), so it maps to one opaque SQL column same as any
// other type - the system decides how the value gets serialized into it.
const con_todos_los_tipos = zigma.defineEntity(.{
    .pk = .{"id"},
    .fields = zigma.record(aida.type_defs, .{
        .id = .{ .type = "text" },
        .cantidad = .{ .type = "integer" },
        .activo = .{ .type = "boolean" },
        .fecha_de_alta = .{ .type = "fecha" },
        .contacto = .{ .type = "email" },
    }),
});
const con_todos_los_tipos_info = zigma.completeEntity(con_todos_los_tipos);
const con_todos_los_tipos_ddl = sql.createTableSql(aida.sql_type_defs, "con_todos_los_tipos", con_todos_los_tipos_info);

test "maps every domain type of the system to SQL, including one backed by a nested struct (fecha)" {
    try expectEqualStrings(
        \\CREATE TABLE con_todos_los_tipos (
        \\    id TEXT NOT NULL,
        \\    cantidad INTEGER,
        \\    activo BOOLEAN,
        \\    fecha_de_alta TEXT,
        \\    contacto TEXT,
        \\    PRIMARY KEY (id)
        \\);
    , con_todos_los_tipos_ddl);
}

// aida.alumnos has no fks/uks: isolates NOT NULL from the other pending
// clauses, so this test won't need updating again once fks/uks land.
const alumnos_info = zigma.completeEntity(aida.alumnos);
const alumnos_ddl = sql.createTableSql(aida.sql_type_defs, "alumnos", alumnos_info);

test "NOT NULL for nullable: false fields, omitted for the nullable: true default" {
    try expectEqualStrings(
        \\CREATE TABLE alumnos (
        \\    alumno TEXT NOT NULL,
        \\    apellido TEXT NOT NULL,
        \\    nombres TEXT NOT NULL,
        \\    email TEXT,
        \\    PRIMARY KEY (alumno)
        \\);
    , alumnos_ddl);
}

// Ad-hoc (not an aida entity with fks) so this stays isolated from FK work.
const combinacion = zigma.defineEntity(.{
    .pk = .{ "a", "b" },
    .fields = zigma.record(zigma.common_type_defs, .{
        .a = .{ .type = "text" },
        .b = .{ .type = "text" },
        .detalle = .{ .type = "text" },
    }),
});
const combinacion_info = zigma.completeEntity(combinacion);
const combinacion_ddl = sql.createTableSql(minimal_sql_types, "combinacion", combinacion_info);

test "PRIMARY KEY lists every pk field, in order, for a composite pk" {
    try expectEqualStrings(
        \\CREATE TABLE combinacion (
        \\    a TEXT NOT NULL,
        \\    b TEXT NOT NULL,
        \\    detalle TEXT,
        \\    PRIMARY KEY (a, b)
        \\);
    , combinacion_ddl);
}

// aida.materias has a uk and no fks: isolates UNIQUE (and exercises NOT
// NULL again, on denominacion) from FK work.
const materias_info = zigma.completeEntity(aida.materias);
const materias_ddl = sql.createTableSql(aida.sql_type_defs, "materias", materias_info);

test "UNIQUE from uks" {
    try expectEqualStrings(
        \\CREATE TABLE materias (
        \\    materia TEXT NOT NULL,
        \\    denominacion TEXT NOT NULL,
        \\    PRIMARY KEY (materia),
        \\    UNIQUE (denominacion)
        \\);
    , materias_ddl);
}

// Ad-hoc pair (not aida.cursos): keeps this isolated to just "fk with
// matching source/target names", instead of aida.cursos' three fks at once.
const padre = zigma.defineEntity(.{
    .pk = .{"padre"},
    .fields = zigma.record(zigma.common_type_defs, .{
        .padre = .{ .type = "text" },
    }),
});
const hijo = zigma.defineEntity(.{
    .pk = .{"hijo"},
    .fks = .{ .padre = .{ .entity = "padre", .fields = padre.pk } },
    .fields = zigma.record(zigma.common_type_defs, .{
        .hijo = .{ .type = "text" },
        .padre = .{ .type = "text" },
    }),
});
const hijo_info = zigma.completeEntity(hijo);
const hijo_ddl = sql.createTableSql(minimal_sql_types, "hijo", hijo_info);

test "FOREIGN KEY when the source and target field are named the same" {
    try expectEqualStrings(
        \\CREATE TABLE hijo (
        \\    hijo TEXT NOT NULL,
        \\    padre TEXT,
        \\    PRIMARY KEY (hijo),
        \\    FOREIGN KEY (padre) REFERENCES padre(padre)
        \\);
    , hijo_ddl);
}

// Reflexive fk with a renamed source field (like aida.docentes.jefe), but
// ad-hoc so this test doesn't also depend on docentes having no other
// unimplemented feature in play.
const persona = zigma.defineEntity(.{
    .pk = .{"persona"},
    .fks = .{ .jefe = .{ .entity = "persona", .fields = .{ .jefe = "persona" } } },
    .fields = zigma.record(zigma.common_type_defs, .{
        .persona = .{ .type = "text" },
        .jefe = .{ .type = "text" },
    }),
});
const persona_info = zigma.completeEntity(persona);
const persona_ddl = sql.createTableSql(minimal_sql_types, "persona", persona_info);

test "FOREIGN KEY with a renamed source field (reflexive fk)" {
    try expectEqualStrings(
        \\CREATE TABLE persona (
        \\    persona TEXT NOT NULL,
        \\    jefe TEXT,
        \\    PRIMARY KEY (persona),
        \\    FOREIGN KEY (jefe) REFERENCES persona(persona)
        \\);
    , persona_ddl);
}

// Two distinct fks to the same target entity (like aida.mesas.presidente
// and .vocal, both -> docentes), ad-hoc to isolate from mesas' other fk.
const objetivo = zigma.defineEntity(.{
    .pk = .{"objetivo"},
    .fields = zigma.record(zigma.common_type_defs, .{
        .objetivo = .{ .type = "text" },
    }),
});
const disputa = zigma.defineEntity(.{
    .pk = .{"disputa"},
    .fks = .{
        .demandante = .{ .entity = "objetivo", .fields = .{ .demandante = "objetivo" } },
        .demandado = .{ .entity = "objetivo", .fields = .{ .demandado = "objetivo" } },
    },
    .fields = zigma.record(zigma.common_type_defs, .{
        .disputa = .{ .type = "text" },
        .demandante = .{ .type = "text" },
        .demandado = .{ .type = "text" },
    }),
});
const disputa_info = zigma.completeEntity(disputa);
const disputa_ddl = sql.createTableSql(minimal_sql_types, "disputa", disputa_info);

test "two distinct fks to the same target entity do not overwrite each other" {
    try expectEqualStrings(
        \\CREATE TABLE disputa (
        \\    disputa TEXT NOT NULL,
        \\    demandante TEXT,
        \\    demandado TEXT,
        \\    PRIMARY KEY (disputa),
        \\    FOREIGN KEY (demandante) REFERENCES objetivo(objetivo),
        \\    FOREIGN KEY (demandado) REFERENCES objetivo(objetivo)
        \\);
    , disputa_ddl);
}

// A genuine cycle between two distinct entities (not reflexive): nodo_a has
// a fk to nodo_b and nodo_b has a fk to nodo_a. Wrapped in defineEntities to
// also confirm zigma's own global fk check accepts the cycle. schemaSql
// emits nodo_a (which references nodo_b) before nodo_b is defined: SQLite
// does not require the referenced table to exist yet at CREATE TABLE time,
// only at DML time, so inline FOREIGN KEY clauses in declaration order are
// fine as-is - no reordering or ALTER TABLE ADD CONSTRAINT needed.
const nodo_a = zigma.defineEntity(.{
    .pk = .{"a"},
    .fks = .{ .b = .{ .entity = "nodo_b", .fields = .{ .b = "b" } } },
    .fields = zigma.record(zigma.common_type_defs, .{
        .a = .{ .type = "text" },
        .b = .{ .type = "text" },
    }),
});
const nodo_b = zigma.defineEntity(.{
    .pk = .{"b"},
    .fks = .{ .a = .{ .entity = "nodo_a", .fields = .{ .a = "a" } } },
    .fields = zigma.record(zigma.common_type_defs, .{
        .b = .{ .type = "text" },
        .a = .{ .type = "text" },
    }),
});
const ciclo = zigma.defineEntities(.{ .nodo_a = nodo_a, .nodo_b = nodo_b });
const ciclo_ddl = sql.schemaSql(minimal_sql_types, ciclo);

test "cyclic fks between two distinct entities generate both CREATE TABLEs" {
    try expectEqualStrings(
        \\CREATE TABLE nodo_a (
        \\    a TEXT NOT NULL,
        \\    b TEXT,
        \\    PRIMARY KEY (a),
        \\    FOREIGN KEY (b) REFERENCES nodo_b(b)
        \\);
        \\
        \\CREATE TABLE nodo_b (
        \\    b TEXT NOT NULL,
        \\    a TEXT,
        \\    PRIMARY KEY (b),
        \\    FOREIGN KEY (a) REFERENCES nodo_a(a)
        \\);
    , ciclo_ddl);
}

const aida_schema_ddl = sql.schemaSql(aida.sql_type_defs, aida.entity_defs);

test "generates the full aida schema: one CREATE TABLE per entity, in declaration order" {
    try expectEqualStrings(
        \\CREATE TABLE docentes (
        \\    docente TEXT NOT NULL,
        \\    apellido TEXT NOT NULL,
        \\    nombres TEXT NOT NULL,
        \\    cargo TEXT,
        \\    email TEXT,
        \\    email_alternativo TEXT,
        \\    jefe TEXT,
        \\    PRIMARY KEY (docente),
        \\    FOREIGN KEY (jefe) REFERENCES docentes(docente)
        \\);
        \\
        \\CREATE TABLE materias (
        \\    materia TEXT NOT NULL,
        \\    denominacion TEXT NOT NULL,
        \\    PRIMARY KEY (materia),
        \\    UNIQUE (denominacion)
        \\);
        \\
        \\CREATE TABLE periodos (
        \\    periodo TEXT NOT NULL,
        \\    PRIMARY KEY (periodo)
        \\);
        \\
        \\CREATE TABLE cursos (
        \\    periodo TEXT NOT NULL,
        \\    materia TEXT NOT NULL,
        \\    docente TEXT,
        \\    PRIMARY KEY (periodo, materia),
        \\    FOREIGN KEY (periodo) REFERENCES periodos(periodo),
        \\    FOREIGN KEY (materia) REFERENCES materias(materia),
        \\    FOREIGN KEY (docente) REFERENCES docentes(docente)
        \\);
        \\
        \\CREATE TABLE clases (
        \\    periodo TEXT NOT NULL,
        \\    materia TEXT NOT NULL,
        \\    orden INTEGER NOT NULL,
        \\    fecha TEXT,
        \\    tema TEXT,
        \\    PRIMARY KEY (periodo, materia, orden),
        \\    FOREIGN KEY (periodo, materia) REFERENCES cursos(periodo, materia)
        \\);
        \\
        \\CREATE TABLE alumnos (
        \\    alumno TEXT NOT NULL,
        \\    apellido TEXT NOT NULL,
        \\    nombres TEXT NOT NULL,
        \\    email TEXT,
        \\    PRIMARY KEY (alumno)
        \\);
        \\
        \\CREATE TABLE preguntas (
        \\    periodo TEXT NOT NULL,
        \\    materia TEXT NOT NULL,
        \\    orden INTEGER NOT NULL,
        \\    pregunta INTEGER NOT NULL,
        \\    formulacion TEXT NOT NULL,
        \\    aclaraciones TEXT,
        \\    tipo_respuesta TEXT NOT NULL,
        \\    PRIMARY KEY (periodo, materia, orden, pregunta),
        \\    FOREIGN KEY (periodo, materia, orden) REFERENCES clases(periodo, materia, orden)
        \\);
        \\
        \\CREATE TABLE opciones (
        \\    periodo TEXT NOT NULL,
        \\    materia TEXT NOT NULL,
        \\    orden INTEGER NOT NULL,
        \\    pregunta INTEGER NOT NULL,
        \\    opcion TEXT NOT NULL,
        \\    detalle TEXT,
        \\    PRIMARY KEY (periodo, materia, orden, pregunta, opcion),
        \\    FOREIGN KEY (periodo, materia, orden, pregunta) REFERENCES preguntas(periodo, materia, orden, pregunta)
        \\);
        \\
        \\CREATE TABLE inscripciones (
        \\    periodo TEXT NOT NULL,
        \\    materia TEXT NOT NULL,
        \\    alumno TEXT NOT NULL,
        \\    PRIMARY KEY (periodo, materia, alumno),
        \\    FOREIGN KEY (periodo, materia) REFERENCES cursos(periodo, materia),
        \\    FOREIGN KEY (alumno) REFERENCES alumnos(alumno)
        \\);
        \\
        \\CREATE TABLE presencias (
        \\    periodo TEXT NOT NULL,
        \\    materia TEXT NOT NULL,
        \\    alumno TEXT NOT NULL,
        \\    orden INTEGER NOT NULL,
        \\    PRIMARY KEY (periodo, materia, alumno, orden),
        \\    FOREIGN KEY (periodo, materia, alumno) REFERENCES inscripciones(periodo, materia, alumno),
        \\    FOREIGN KEY (periodo, materia, orden) REFERENCES clases(periodo, materia, orden)
        \\);
        \\
        \\CREATE TABLE mesas (
        \\    periodo TEXT NOT NULL,
        \\    materia TEXT NOT NULL,
        \\    fecha TEXT NOT NULL,
        \\    presidente TEXT,
        \\    vocal TEXT,
        \\    PRIMARY KEY (periodo, materia, fecha),
        \\    FOREIGN KEY (periodo, materia) REFERENCES cursos(periodo, materia),
        \\    FOREIGN KEY (presidente) REFERENCES docentes(docente),
        \\    FOREIGN KEY (vocal) REFERENCES docentes(docente)
        \\);
    , aida_schema_ddl);
}
