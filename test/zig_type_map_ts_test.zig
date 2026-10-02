//! Tests for the type resolution of `zig_type_map_ts.tsType`: all the
//! conversion information lives in the framework's `ts_type_defs` (keyed by
//! `@typeName` of the Zig type); a system only names its domains in
//! `type_defs`, which resolve through their Zig type. The unmapped cases are
//! "does not compile" cases (test/compile_errors/zig_type_map_ts_*).

const std = @import("std");
const zigma = @import("zigma");
const map_ts = @import("zig_type_map_ts");
const expectEqualStrings = std.testing.expectEqualStrings;

const Punto = struct { x: i16, y: u16 };

/// A minimal system: the framework's common types plus an alias of a
/// primitive (`email`) and a struct-backed domain (`punto`).
const type_defs = zigma.defineTypes(zigma.merge(.{ zigma.common_type_defs, .{
    .email = zigma.common_type_defs.text,
    .punto = zigma.TypeDef{ .Type = Punto },
} }));

fn tsTypeOf(comptime T: type) []const u8 {
    return map_ts.tsType(type_defs, @typeName(T));
}

// ---- Zig primitives, by @typeName ----

test "bool maps to boolean" {
    try expectEqualStrings("boolean", tsTypeOf(bool));
}

test "integers that fit in 32 signed bits map to number" {
    try expectEqualStrings("number", tsTypeOf(u8));
    try expectEqualStrings("number", tsTypeOf(i8));
    try expectEqualStrings("number", tsTypeOf(i16));
    try expectEqualStrings("number", tsTypeOf(u16));
    try expectEqualStrings("number", tsTypeOf(i32));
}

test "i64 maps to bigint" {
    // pg returns BIGINT as a string by default; the generated pgTypes reads
    // it as a BigInt so TS really sees a bigint.
    try expectEqualStrings("bigint", tsTypeOf(i64));
}

test "a byte slice maps to string" {
    try expectEqualStrings("string", tsTypeOf([]const u8));
}

// ---- named domains, resolved through their Zig type ----

test "a common domain resolves through its Zig type" {
    try expectEqualStrings("string", map_ts.tsType(type_defs, "text"));
    try expectEqualStrings("bigint", map_ts.tsType(type_defs, "integer"));
    try expectEqualStrings("boolean", map_ts.tsType(type_defs, "boolean"));
}

test "a system domain aliasing a primitive keeps its name and resolves through its Zig type" {
    try expectEqualStrings("string", map_ts.tsType(type_defs, "email"));
}

test "a struct-backed domain is an inline object type, one member per field" {
    try expectEqualStrings("{ x: number; y: number }", map_ts.tsType(type_defs, "punto"));
}
