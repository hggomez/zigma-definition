//! Tests for the Zig -> Postgres type map (`src/zig_type_map_sql.zig`): which
//! Postgres type stores each Zig type, and the DOMAIN that restricts an
//! integer to its real Zig interval when the Postgres type is wider. The
//! rejections are compile-error cases (`test/compile_errors/zig_type_map_sql_*.zig`).

const std = @import("std");
const map = @import("zig_type_map_sql");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

/// `t` is an integer stored in `base`, with the Zig interval `min..max`, and
/// restricted by the DOMAIN `domain` (null: `base` has exactly that range).
fn expectInteger(
    comptime t: map.SqlType,
    comptime base: map.PgInteger,
    comptime min: comptime_int,
    comptime max: comptime_int,
    comptime domain: ?[]const u8,
) !void {
    try expect(t == .integer);
    try expect(t.integer.base == base);
    try expect(t.integer.min == min);
    try expect(t.integer.max == max);
    if (domain) |name| {
        try expect(t.integer.domain != null);
        try expectEqualStrings(name, t.integer.domain.?);
    } else {
        try expect(t.integer.domain == null);
    }
}

// ---- primitives ----

test "bool maps to BOOLEAN" {
    try expect(comptime map.sqlTypeOf(bool) == .boolean);
}

test "a byte slice maps to TEXT" {
    try expect(comptime map.sqlTypeOf([]const u8) == .text);
}

// ---- integers: the smallest Postgres integer that holds the whole interval ----

test "an integer with exactly the range of a Postgres integer maps to it, no domain" {
    try expectInteger(comptime map.sqlTypeOf(i16), .smallint, -32768, 32767, null);
    try expectInteger(comptime map.sqlTypeOf(i32), .integer, -2147483648, 2147483647, null);
    try expectInteger(comptime map.sqlTypeOf(i64), .bigint, -(1 << 63), (1 << 63) - 1, null);
}

// A Postgres integer wider than the Zig type would accept values outside the
// Zig interval (a u8 in a SMALLINT takes -5 or 300): a DOMAIN named after the
// Zig type restricts it to the real interval.

test "a narrower integer maps to the smallest Postgres integer that holds it, restricted by a domain" {
    try expectInteger(comptime map.sqlTypeOf(u8), .smallint, 0, 255, "zig_u8");
    try expectInteger(comptime map.sqlTypeOf(i8), .smallint, -128, 127, "zig_i8");
    try expectInteger(comptime map.sqlTypeOf(u16), .integer, 0, 65535, "zig_u16");
    try expectInteger(comptime map.sqlTypeOf(u32), .bigint, 0, (1 << 32) - 1, "zig_u32");
}

test "any width works: the domain is named after the Zig type (u7, i33)" {
    try expectInteger(comptime map.sqlTypeOf(u7), .smallint, 0, 127, "zig_u7");
    try expectInteger(comptime map.sqlTypeOf(i33), .bigint, -(1 << 32), (1 << 32) - 1, "zig_i33");
}

test "the boundaries between Postgres integers: u15 fits SMALLINT, u16 needs INTEGER; u31 INTEGER, u32 BIGINT" {
    try expectInteger(comptime map.sqlTypeOf(u15), .smallint, 0, 32767, "zig_u15");
    try expectInteger(comptime map.sqlTypeOf(u16), .integer, 0, 65535, "zig_u16");
    try expectInteger(comptime map.sqlTypeOf(i17), .integer, -(1 << 16), (1 << 16) - 1, "zig_i17");
    try expectInteger(comptime map.sqlTypeOf(u31), .integer, 0, (1 << 31) - 1, "zig_u31");
    try expectInteger(comptime map.sqlTypeOf(u63), .bigint, 0, (1 << 63) - 1, "zig_u63");
}
