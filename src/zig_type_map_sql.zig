//! Zig -> Postgres type map. Given a Zig type (a primitive, the `Type` behind
//! a domain type of `type_defs`), `sqlTypeOf` describes the Postgres type that
//! stores it: an integer goes in the smallest Postgres integer whose range
//! contains its whole Zig interval, and when that range is wider than the Zig
//! one, a `DOMAIN` named after the Zig type restricts it to the real interval.
//! A struct is a composite type, its fields mapped the same way.
//! It does not render SQL: the generators write the text (the column type,
//! the `CREATE DOMAIN`, the `CREATE TYPE`) from this description.

const std = @import("std");

pub const SqlKind = enum { boolean, text, integer, composite };

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

/// A field of a struct mapped to a Postgres composite type, in declaration
/// order.
pub const SqlField = struct { name: []const u8, type: SqlType };

pub const SqlType = union(SqlKind) {
    boolean,
    text,
    integer: SqlInteger,
    /// a struct: a Postgres composite type with one attribute per field. The
    /// composite has no name here (the Zig type has no SQL name): the
    /// generator names it after the domain. A field cannot be a struct itself
    /// (nested structs have no SQL mapping yet).
    composite: []const SqlField,
};

/// The Postgres type that stores the Zig type `T`: `bool`, `[]const u8`, an
/// integer whose interval fits in a BIGINT, or a struct of those (a
/// composite). Anything else is a compile error.
pub fn sqlTypeOf(comptime T: type) SqlType {
    if (T == bool) return .boolean;
    if (T == []const u8) return .text;
    return switch (@typeInfo(T)) {
        .int => .{ .integer = integerOf(T) },
        .@"struct" => .{ .composite = compositeFieldsOf(T) },
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

fn compositeFieldsOf(comptime T: type) []const SqlField {
    const info = @typeInfo(T).@"struct";
    var fields: [info.field_names.len]SqlField = undefined;
    for (info.field_names, info.field_types, 0..) |name, field_type, i| {
        if (@typeInfo(field_type) == .@"struct")
            @compileError("field '" ++ name ++ "' is a struct: nested structs have no SQL mapping yet");
        fields[i] = .{ .name = name, .type = sqlTypeOf(field_type) };
    }
    const result = fields;
    return &result;
}
