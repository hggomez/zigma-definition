//! Tests for DDL (CREATE TABLE) generation from zigma EntityInfo, driving the
//! implementation of `sql_generator.zig`. Fixtures reuse `aida` entities once they
//! exercise a pattern the vocabulary already has (composite pk, uk, fks);
//! ad-hoc fixtures are defined here only for the minimal base-format cases.

const std = @import("std");
const zigma = @import("zigma");
const aida = @import("aida");
const sql = @import("sql_generator");
const expectEqualStrings = std.testing.expectEqualStrings;

// The generator takes the system's type_defs: each column's SQL type comes
// from the Zig type behind its domain (zig_type_map_sql.sqlTypeOf).
const types = zigma.common_type_defs;

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
// to do `@field(type_defs, field.type)` internally.
const cosa_info = zigma.completeEntity(cosa);
const cosa_ddl = sql.createTableSql(types, "cosa", cosa_info);

test "generates a CREATE TABLE with the entity's single column and its SQL type" {
    try expectEqualStrings(
        \\CREATE TABLE cosa (
        \\    cosa TEXT NOT NULL,
        \\    PRIMARY KEY (cosa)
        \\);
    , cosa_ddl);
}

const varias = zigma.defineEntity(.{
    .pk = .{"id"},
    .fields = zigma.record(zigma.common_type_defs, .{
        .id = .{ .type = "text" },
        .cantidad = .{ .type = "integer" },
        .activo = .{ .type = "boolean" },
    }),
});
const varias_info = zigma.completeEntity(varias);
const varias_ddl = sql.createTableSql(types, "varias", varias_info);

test "maps each field to the SQL type that corresponds to it, not just the first one" {
    try expectEqualStrings(
        \\CREATE TABLE varias (
        \\    id TEXT NOT NULL,
        \\    cantidad BIGINT,
        \\    activo BOOLEAN,
        \\    PRIMARY KEY (id)
        \\);
    , varias_ddl);
}

// cosa and varias are independent (no fk between them): fk clauses are a
// later step, this one only checks the multi-entity aggregation.
const dos_entidades = zigma.defineEntities(.{ .cosa = cosa, .varias = varias });
const dos_entidades_ddl = sql.schemaSql(types, dos_entidades);

test "schemaSql generates one CREATE TABLE per entity, in declaration order, for more than one entity" {
    try expectEqualStrings(
        \\CREATE TABLE cosa (
        \\    cosa TEXT NOT NULL,
        \\    PRIMARY KEY (cosa)
        \\);
        \\
        \\CREATE TABLE varias (
        \\    id TEXT NOT NULL,
        \\    cantidad BIGINT,
        \\    activo BOOLEAN,
        \\    PRIMARY KEY (id)
        \\);
    , dos_entidades_ddl);
}

// Every primitive domain of aida, resolved through its Zig type: text
// ([]const u8) -> TEXT, integer (i64) -> BIGINT, boolean -> BOOLEAN, and
// email, a system domain aliasing text, -> TEXT. aida.fecha (a struct) is
// left out: it comes with the composite type.
const con_todos_los_tipos = zigma.defineEntity(.{
    .pk = .{"id"},
    .fields = zigma.record(aida.type_defs, .{
        .id = .{ .type = "text" },
        .cantidad = .{ .type = "integer" },
        .activo = .{ .type = "boolean" },
        .contacto = .{ .type = "email" },
    }),
});
const con_todos_los_tipos_info = zigma.completeEntity(con_todos_los_tipos);
const con_todos_los_tipos_ddl = sql.createTableSql(aida.type_defs, "con_todos_los_tipos", con_todos_los_tipos_info);

test "maps every primitive domain type of the system to SQL through its Zig type" {
    try expectEqualStrings(
        \\CREATE TABLE con_todos_los_tipos (
        \\    id TEXT NOT NULL,
        \\    cantidad BIGINT,
        \\    activo BOOLEAN,
                \\    contacto TEXT,
        \\    PRIMARY KEY (id)
        \\);
    , con_todos_los_tipos_ddl);
}

// aida.alumnos has no fks/uks: isolates NOT NULL from the other pending
// clauses, so this test won't need updating again once fks/uks land.
const alumnos_info = zigma.completeEntity(aida.alumnos);
const alumnos_ddl = sql.createTableSql(aida.type_defs, "alumnos", alumnos_info);

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
const combinacion_ddl = sql.createTableSql(types, "combinacion", combinacion_info);

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
const materias_ddl = sql.createTableSql(aida.type_defs, "materias", materias_info);

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
const hijo_ddl = sql.createTableSql(types, "hijo", hijo_info);

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
const persona_ddl = sql.createTableSql(types, "persona", persona_info);

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
const disputa_ddl = sql.createTableSql(types, "disputa", disputa_info);

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
const ciclo_ddl = sql.schemaSql(types, ciclo);

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

// ---- narrow integers: a DOMAIN restricts the column to the Zig interval ----
//
// A Postgres integer wider than the Zig type would accept values outside its
// interval (a u8 in a SMALLINT takes -5 or 300). The column is typed with a
// DOMAIN named after the Zig type, emitted by schemaSql before the tables.

const medidas_types = zigma.defineTypes(zigma.merge(.{ zigma.common_type_defs, .{
    .cantidad = zigma.TypeDef{ .Type = u8 },
    .edad = zigma.TypeDef{ .Type = u8 },
    .temperatura = zigma.TypeDef{ .Type = i8 },
    .poblacion = zigma.TypeDef{ .Type = u32 },
    .indice = zigma.TypeDef{ .Type = i16 },
} }));

// medidas: one narrow integer of each Postgres width, and an i16 that has
// exactly the range of SMALLINT (no domain).
const medidas = zigma.defineEntity(.{
    .pk = .{"id"},
    .fields = zigma.record(medidas_types, .{
        .id = .{ .type = "text" },
        .cantidad = .{ .type = "cantidad" },
        .temperatura = .{ .type = "temperatura" },
        .poblacion = .{ .type = "poblacion" },
        .indice = .{ .type = "indice" },
    }),
});
const medidas_info = zigma.completeEntity(medidas);
const medidas_ddl = sql.createTableSql(medidas_types, "medidas", medidas_info);

test "a narrow integer column is typed with the domain of its Zig type; an exact one with the Postgres integer" {
    try expectEqualStrings(
        \\CREATE TABLE medidas (
        \\    id TEXT NOT NULL,
        \\    cantidad zig_u8,
        \\    temperatura zig_i8,
        \\    poblacion zig_u32,
        \\    indice SMALLINT,
        \\    PRIMARY KEY (id)
        \\);
    , medidas_ddl);
}

// stock: `cantidad` is a u8 again and `edad` is another domain backed by u8:
// zig_u8 is emitted once, in order of first appearance, before every table.
const stock = zigma.defineEntity(.{
    .pk = .{"item"},
    .fields = zigma.record(medidas_types, .{
        .item = .{ .type = "text" },
        .cantidad = .{ .type = "cantidad" },
        .edad_minima = .{ .type = "edad" },
    }),
});
const con_dominios = zigma.defineEntities(.{ .medidas = medidas, .stock = stock });
const con_dominios_ddl = sql.schemaSql(medidas_types, con_dominios);

test "schemaSql emits each domain once, in order of first appearance, before the tables" {
    try expectEqualStrings(
        \\CREATE DOMAIN zig_u8 AS SMALLINT CHECK (VALUE BETWEEN 0 AND 255);
        \\
        \\CREATE DOMAIN zig_i8 AS SMALLINT CHECK (VALUE BETWEEN -128 AND 127);
        \\
        \\CREATE DOMAIN zig_u32 AS BIGINT CHECK (VALUE BETWEEN 0 AND 4294967295);
        \\
        \\CREATE TABLE medidas (
        \\    id TEXT NOT NULL,
        \\    cantidad zig_u8,
        \\    temperatura zig_i8,
        \\    poblacion zig_u32,
        \\    indice SMALLINT,
        \\    PRIMARY KEY (id)
        \\);
        \\
        \\CREATE TABLE stock (
        \\    item TEXT NOT NULL,
        \\    cantidad zig_u8,
        \\    edad_minima zig_u8,
        \\    PRIMARY KEY (item)
        \\);
    , con_dominios_ddl);
}
