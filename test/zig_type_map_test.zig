//! Tests for the framework's Zig primitive type -> Postgres / TypeScript maps
//! (`zig_type_map_sql.primitive_sql_types`, `zig_type_map_ts.primitive_ts_types`), looked up with
//! the same `sqlType` / `tsType` used for a system's domain maps, keyed by
//! `@typeName`. The unsupported types are covered as "does not compile" cases
//! (test/compile_errors/zig_type_map_*).

const std = @import("std");
const map_sql = @import("zig_type_map_sql");
const map_ts = @import("zig_type_map_ts");
const expectEqualStrings = std.testing.expectEqualStrings;

fn sqlTypeOf(comptime T: type) []const u8 {
    return map_sql.sqlType(map_sql.primitive_sql_types, @typeName(T));
}

fn tsTypeOf(comptime T: type) []const u8 {
    return map_ts.tsType(map_ts.primitive_ts_types, @typeName(T));
}

test "bool maps to BOOLEAN / boolean" {
    try expectEqualStrings("BOOLEAN", sqlTypeOf(bool));
    try expectEqualStrings("boolean", tsTypeOf(bool));
}

test "integers that fit in 16 signed bits map to SMALLINT / number" {
    try expectEqualStrings("SMALLINT", sqlTypeOf(u8));
    try expectEqualStrings("SMALLINT", sqlTypeOf(i8));
    try expectEqualStrings("SMALLINT", sqlTypeOf(i16));
    try expectEqualStrings("number", tsTypeOf(u8));
    try expectEqualStrings("number", tsTypeOf(i8));
    try expectEqualStrings("number", tsTypeOf(i16));
}

test "integers that fit in 32 signed bits but not 16 map to INTEGER / number" {
    // u16 does not fit in SMALLINT (max 32767)
    try expectEqualStrings("INTEGER", sqlTypeOf(u16));
    try expectEqualStrings("INTEGER", sqlTypeOf(i32));
    try expectEqualStrings("number", tsTypeOf(u16));
    try expectEqualStrings("number", tsTypeOf(i32));
}

test "a byte slice maps to TEXT / string" {
    try expectEqualStrings("TEXT", sqlTypeOf([]const u8));
    try expectEqualStrings("string", tsTypeOf([]const u8));
}
