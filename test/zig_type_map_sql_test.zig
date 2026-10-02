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

test "an integer whose range is exactly that of a Postgres integer maps to it" {
    try expectEqualStrings("SMALLINT", sqlTypeOf(i16));
    try expectEqualStrings("INTEGER", sqlTypeOf(i32));
}

test "an integer narrower than its Postgres integer maps to a domain with the Zig range" {
    // the column must not hold what the Zig type cannot: zig_u8 is a SMALLINT
    // checked to 0..255 (see createDomainSql in sql_generator)
    try expectEqualStrings("zig_u8", sqlTypeOf(u8));
    try expectEqualStrings("zig_i8", sqlTypeOf(i8));
    // u16 does not fit in SMALLINT (max 32767): an INTEGER checked to 0..65535
    try expectEqualStrings("zig_u16", sqlTypeOf(u16));
}

test "sqlDomain gives the Postgres integer and the Zig range of a narrow integer, null otherwise" {
    const d = map_sql.sqlDomain(u8).?;
    try expectEqualStrings("zig_u8", d.name);
    try expectEqualStrings("SMALLINT", d.base);
    try std.testing.expect(d.min == 0 and d.max == 255);
    const d16 = map_sql.sqlDomain(u16).?;
    try expectEqualStrings("INTEGER", d16.base);
    try std.testing.expect(d16.min == 0 and d16.max == 65535);
    try std.testing.expect(map_sql.sqlDomain(i16) == null);
    try std.testing.expect(map_sql.sqlDomain(i64) == null);
    try std.testing.expect(map_sql.sqlDomain(bool) == null);
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
