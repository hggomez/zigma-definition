//! Prints the full PostgreSQL DDL for the aida example to stdout. Driven by
//! `zig build create-database` (see build.zig), which pipes this into
//! `psql` running inside the Postgres container from docker-compose.yml.

const std = @import("std");
const aida = @import("aida");
const schema_sql = @import("schema_sql");

// PostgreSQL type for each aida domain type: system-specific, not part of
// the entity structure itself, supplied here the same way any caller of
// schema_sql.createSchemaStatements has to.
const postgres_types = .{
    .text = "TEXT",
    .integer = "INTEGER",
    .boolean = "BOOLEAN",
    .fecha = "DATE",
    .email = "TEXT",
};

const sql_text = schema_sql.createSchemaStatements(aida.entity_defs, postgres_types);

pub fn main() !void {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    const io = threaded.io();
    try std.Io.File.stdout().writeStreamingAll(io, sql_text);
}
