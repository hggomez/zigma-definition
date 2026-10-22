//! Zig -> TypeScript type map. Given a Zig type (a primitive or a struct, the
//! `Type` behind a domain type of `type_defs`), `tsTypeOf` describes the TS
//! type that represents it exactly: its kind, the real interval of an integer
//! (from `std.math.minInt`/`maxInt`), and the fields of a struct, mapped
//! recursively. It does not render TS source: the generators write the text
//! from this description, since the text depends on their context (a
//! nullable field is `T | null`, which the type alone cannot know).

const std = @import("std");

pub const TsKind = enum { boolean, string, number, bigint, object };

/// The interval of a Zig integer type, `minInt(T)..maxInt(T)`.
pub const Interval = struct { min: comptime_int, max: comptime_int };

/// A field of a struct mapped to a TS object, in declaration order.
pub const TsField = struct { name: []const u8, type: TsType };

pub const TsType = union(TsKind) {
    boolean,
    string,
    /// an integer whose whole interval is exact in a JS `number`
    /// (within ±(2^53 - 1))
    number: Interval,
    /// an integer with some value outside the exact range of a `number`
    bigint: Interval,
    object: []const TsField,
};

/// The largest integer a JS `number` holds exactly (Number.MAX_SAFE_INTEGER).
const max_safe_integer = (1 << 53) - 1;

/// The TS type that represents the Zig type `T` exactly: `bool`, `[]const u8`,
/// any integer, or a struct of those (recursively). Anything else is a
/// compile error.
pub fn tsTypeOf(comptime T: type) TsType {
    if (T == bool) return .boolean;
    if (T == []const u8) return .string;
    return switch (@typeInfo(T)) {
        .int => integerOf(T),
        .@"struct" => .{ .object = objectFieldsOf(T) },
        else => @compileError("Zig type '" ++ @typeName(T) ++ "' has no TS mapping"),
    };
}

fn integerOf(comptime T: type) TsType {
    const interval: Interval = .{ .min = std.math.minInt(T), .max = std.math.maxInt(T) };
    if (interval.min >= -max_safe_integer and interval.max <= max_safe_integer)
        return .{ .number = interval };
    return .{ .bigint = interval };
}

fn objectFieldsOf(comptime T: type) []const TsField {
    const info = @typeInfo(T).@"struct";
    var fields: [info.field_names.len]TsField = undefined;
    for (info.field_names, info.field_types, 0..) |name, field_type, i| {
        fields[i] = .{ .name = name, .type = tsTypeOf(field_type) };
    }
    const result = fields;
    return &result;
}
