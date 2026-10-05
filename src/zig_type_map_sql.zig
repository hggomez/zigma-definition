//! Zig -> Postgres type map. Given a Zig type (a primitive, the `Type` behind
//! a domain type of `type_defs`), `sqlTypeOf` describes the Postgres type that
//! stores it: an integer goes in the smallest Postgres integer whose range
//! contains its whole Zig interval, and when that range is wider than the Zig
//! one, a `DOMAIN` named after the Zig type restricts it to the real interval.
//! It does not render SQL: the generators write the text (the column type,
//! the `CREATE DOMAIN`) from this description.

const std = @import("std");

pub const SqlKind = enum { boolean, text, integer };

/// The Postgres integer types, by width: SMALLINT (i16), INTEGER (i32),
/// BIGINT (i64).
pub const PgInteger = enum { smallint, integer, bigint };

pub const SqlInteger = struct {
    /// the smallest Postgres integer whose range contains `min..max`
    base: PgInteger,
    /// the interval of the Zig type, `minInt(T)..maxInt(T)`
    min: comptime_int,
    max: comptime_int,
    /// the name of the DOMAIN that restricts `base` to `min..max`
    /// (`zig_u8`), or null when `base` has exactly that range
    domain: ?[]const u8,
};

pub const SqlType = union(SqlKind) {
    boolean,
    text,
    integer: SqlInteger,
};

/// The Postgres type that stores the Zig type `T`: `bool`, `[]const u8`, or
/// an integer whose interval fits in a BIGINT. Anything else is a compile
/// error.
pub fn sqlTypeOf(comptime T: type) SqlType {
    if (T == bool) return .boolean;
    if (T == []const u8) return .text;
    return switch (@typeInfo(T)) {
        .int => .{ .integer = integerOf(T) },
        else => @compileError("Zig type '" ++ @typeName(T) ++ "' has no SQL mapping"),
    };
}

/// The Zig integer type with exactly the range of each Postgres integer.
fn rangeOf(comptime base: PgInteger) type {
    return switch (base) {
        .smallint => i16,
        .integer => i32,
        .bigint => i64,
    };
}

fn integerOf(comptime T: type) SqlInteger {
    const min = std.math.minInt(T);
    const max = std.math.maxInt(T);
    for ([_]PgInteger{ .smallint, .integer, .bigint }) |base| {
        const R = rangeOf(base);
        if (min >= std.math.minInt(R) and max <= std.math.maxInt(R)) {
            const exact = min == std.math.minInt(R) and max == std.math.maxInt(R);
            return .{
                .base = base,
                .min = min,
                .max = max,
                .domain = if (exact) null else "zig_" ++ @typeName(T),
            };
        }
    }
    @compileError("Zig type '" ++ @typeName(T) ++ "' does not fit in a Postgres BIGINT");
}
