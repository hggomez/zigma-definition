//! EXAMPLE: prints the CREATE TABLE DDL for the aida system to stdout. Not
//! run against a real database yet, see GOALS.md.

const std = @import("std");
const aida = @import("aida");
const sql_generator = @import("sql_generator");

// A container-level const is always evaluated in comptime scope; calling
// schemaSql from inside main (runtime scope) only yields a runtime copy of
// the result, not comptime-known enough for its internal @field lookups.
const schema_ddl = sql_generator.schemaSql(aida.sql_type_defs, aida.entity_defs);

pub fn main() void {
    std.debug.print("{s}\n", .{schema_ddl});
}
