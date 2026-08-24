//! Tests for the PostgreSQL DDL generator (src/schema_sql.zig), driven off
//! the aida example. Each test uses the smallest aida entity that exercises
//! the rule under test.

const std = @import("std");
const zigma = @import("zigma");
const aida = @import("aida");
const schema_sql = @import("schema_sql");

const expectEqualStrings = std.testing.expectEqualStrings;

// PostgreSQL type for each aida domain type. System-specific: not part of
// the entity structure itself, supplied here the same way a real generation
// script would supply it.
const postgres_types = .{
    .text = "TEXT",
    .integer = "INTEGER",
    .boolean = "BOOLEAN",
};

// declared at container level (comptime scope), not inside the test body:
// see the note in src/schema_sql.zig about "redundant comptime".
const periodos_info = zigma.completeEntity(aida.periodos);
const periodos_sql = schema_sql.createTableStatement("periodos", periodos_info, postgres_types);

test "CREATE TABLE for an entity with a single pk field" {
    // periodo has no explicit `nullable` in its def (so Info says
    // nullable: true, the default) but it IS the pk, so the column must
    // still come out NOT NULL: the pk forces it regardless of that default.
    try expectEqualStrings(
        \\CREATE TABLE periodos (
        \\    periodo TEXT NOT NULL,
        \\    PRIMARY KEY (periodo)
        \\);
    , periodos_sql);
}

// A small stand-in for "a whole example": two entities and one fk between
// them, just enough to exercise createSchemaStatements without the noise of
// asserting against the full (11-entity) aida system.

const fixture_types = zigma.defineTypes(zigma.common_type_defs);

const authors = zigma.defineEntity(.{
    .pk = .{"author"},
    .fields = zigma.record(fixture_types, .{
        .author = .{ .type = "text" },
    }),
});

const books = zigma.defineEntity(.{
    .pk = .{"book"},
    .fks = .{ .author = .{ .entity = "authors", .fields = .{"author"} } },
    .fields = zigma.record(fixture_types, .{
        .book = .{ .type = "text" },
        .author = .{ .type = "text" },
    }),
});

const library_system = zigma.defineEntities(.{ .authors = authors, .books = books });
const library_sql = schema_sql.createSchemaStatements(library_system, postgres_types);

test "creates the whole schema for a system: every table, then every fk" {
    // 'author' on 'books' is not part of its pk and has no explicit
    // nullable, so (unlike periodo above) it stays nullable in the DDL: only
    // pk membership forces NOT NULL, not merely being a fk source field.
    try expectEqualStrings(
        \\CREATE TABLE authors (
        \\    author TEXT NOT NULL,
        \\    PRIMARY KEY (author)
        \\);
        \\
        \\CREATE TABLE books (
        \\    book TEXT NOT NULL,
        \\    author TEXT,
        \\    PRIMARY KEY (book)
        \\);
        \\
        \\ALTER TABLE books ADD FOREIGN KEY (author) REFERENCES authors (author);
    , library_sql);
}
