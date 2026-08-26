//! EXAMPLE: prints the CREATE TABLE DDL for the aida system to stdout. Not
//! run against a real database yet, see GOALS.md.

const std = @import("std");
const aida = @import("aida");
const sql_generator = @import("sql_generator");

// A container-level const is always evaluated in comptime scope; calling
// schemaSql from inside main (runtime scope) only yields a runtime copy of
// the result, not comptime-known enough for its internal @field lookups.
const schema_ddl = sql_generator.schemaSql(aida.sql_type_defs, aida.entity_defs);

// Writes to stdout, not std.debug.print (which always goes to stderr): the
// `create-database` build step pipes this output into psql via
// captureStdOut, so it must land on stdout to be picked up.
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{schema_ddl});
    try stdout.flush();
}
