//! Tests for the type resolution of `zig_type_map_sql.sqlType`: all the
//! conversion information lives in the framework's `sql_type_defs` (keyed by
//! `@typeName` of the Zig type); a system only names its domains in
//! `type_defs`, which resolve through their Zig type. The unmapped cases are
//! "does not compile" cases (test/compile_errors/zig_type_map_sql_*).

const std = @import("std");
const zigma = @import("zigma");
const map_sql = @import("zig_type_map_sql");
const expectEqualStrings = std.testing.expectEqualStrings;

const Punto = struct { x: i16, y: u16 };

/// A minimal system: the framework's common types plus an alias of a
/// primitive (`email`) and a struct-backed domain (`punto`).
const type_defs = zigma.defineTypes(zigma.merge(.{ zigma.common_type_defs, .{
    .email = zigma.common_type_defs.text,
    .punto = zigma.TypeDef{ .Type = Punto },
} }));

fn sqlTypeOf(comptime T: type) []const u8 {
    return map_sql.sqlType(type_defs, @typeName(T));
}

// ---- Zig primitives, by @typeName ----

test "bool maps to BOOLEAN" {
    try expectEqualStrings("BOOLEAN", sqlTypeOf(bool));
}

test "integers that fit in 16 signed bits map to SMALLINT" {
    try expectEqualStrings("SMALLINT", sqlTypeOf(u8));
    try expectEqualStrings("SMALLINT", sqlTypeOf(i8));
    try expectEqualStrings("SMALLINT", sqlTypeOf(i16));
}

test "integers that fit in 32 signed bits but not 16 map to INTEGER" {
    // u16 does not fit in SMALLINT (max 32767)
    try expectEqualStrings("INTEGER", sqlTypeOf(u16));
    try expectEqualStrings("INTEGER", sqlTypeOf(i32));
}

test "i64 maps to BIGINT" {
    try expectEqualStrings("BIGINT", sqlTypeOf(i64));
}

test "a byte slice maps to TEXT" {
    try expectEqualStrings("TEXT", sqlTypeOf([]const u8));
}

// ---- named domains, resolved through their Zig type ----

test "a common domain resolves through its Zig type" {
    try expectEqualStrings("TEXT", map_sql.sqlType(type_defs, "text"));
    try expectEqualStrings("BIGINT", map_sql.sqlType(type_defs, "integer"));
    try expectEqualStrings("BOOLEAN", map_sql.sqlType(type_defs, "boolean"));
}

test "a system domain aliasing a primitive keeps its name and resolves through its Zig type" {
    try expectEqualStrings("TEXT", map_sql.sqlType(type_defs, "email"));
}

test "a struct-backed domain is the composite type named after the domain" {
    try expectEqualStrings("punto", map_sql.sqlType(type_defs, "punto"));
}
