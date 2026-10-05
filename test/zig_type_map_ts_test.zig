//! Tests for the Zig -> TS type map (`src/zig_type_map_ts.zig`): which TS type
//! represents each Zig type exactly, with the real interval of its integers,
//! structs mapped field by field. The rejections are compile-error cases
//! (`test/compile_errors/zig_type_map_ts_*.zig`).

const std = @import("std");
const aida = @import("aida");
const map = @import("zig_type_map_ts");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

/// `t` is an integer of kind `kind` (`.number` or `.bigint`) with exactly the
/// interval `min..max`.
fn expectInteger(comptime t: map.TsType, comptime kind: map.TsKind, comptime min: comptime_int, comptime max: comptime_int) !void {
    try expect(t == kind);
    const interval = @field(t, @tagName(kind));
    try expect(interval.min == min);
    try expect(interval.max == max);
}

// ---- primitives ----

test "bool maps to boolean" {
    try expect(comptime map.tsTypeOf(bool) == .boolean);
}

test "a byte slice maps to string" {
    try expect(comptime map.tsTypeOf([]const u8) == .string);
}

// ---- integers: number while the whole interval is exact in JS ----
//
// A JS number is a double: integers are exact only within ±(2^53 - 1)
// (Number.MAX_SAFE_INTEGER). An integer type is a `number` if its whole
// interval fits there, a `bigint` otherwise. Either way the interval is the
// real one of the Zig type, which the TS type alone does not express.

test "a narrow integer maps to number with its Zig interval" {
    try expectInteger(comptime map.tsTypeOf(u8), .number, 0, 255);
    try expectInteger(comptime map.tsTypeOf(i8), .number, -128, 127);
    try expectInteger(comptime map.tsTypeOf(u16), .number, 0, 65535);
    try expectInteger(comptime map.tsTypeOf(i32), .number, -2147483648, 2147483647);
}

test "the widest integers that are exact in JS still map to number (u53, i53)" {
    try expectInteger(comptime map.tsTypeOf(u53), .number, 0, (1 << 53) - 1);
    try expectInteger(comptime map.tsTypeOf(i53), .number, -(1 << 52), (1 << 52) - 1);
}

test "one bit more is a bigint: u54 reaches 2^54 - 1, i54 reaches -2^53" {
    try expectInteger(comptime map.tsTypeOf(u54), .bigint, 0, (1 << 54) - 1);
    try expectInteger(comptime map.tsTypeOf(i54), .bigint, -(1 << 53), (1 << 53) - 1);
}

test "i64 and u64 map to bigint with their Zig interval" {
    try expectInteger(comptime map.tsTypeOf(i64), .bigint, -(1 << 63), (1 << 63) - 1);
    try expectInteger(comptime map.tsTypeOf(u64), .bigint, 0, (1 << 64) - 1);
}

// ---- structs: an object, each field mapped recursively ----

test "a struct maps to an object with each field mapped, in declaration order (aida.Fecha)" {
    const fields = comptime map.tsTypeOf(aida.Fecha).object;
    try expect(fields.len == 3);
    try expectEqualStrings("año", fields[0].name);
    try expectInteger(fields[0].type, .number, 0, 65535);
    try expectEqualStrings("mes", fields[1].name);
    try expectInteger(fields[1].type, .number, 0, 255);
    try expectEqualStrings("día", fields[2].name);
    try expectInteger(fields[2].type, .number, 0, 255);
}

const Lugar = struct {
    nombre: []const u8,
    activo: bool,
    punto: struct { x: i16, y: i64 },
};

test "a struct inside a struct is mapped recursively" {
    const fields = comptime map.tsTypeOf(Lugar).object;
    try expect(fields.len == 3);
    try expectEqualStrings("nombre", fields[0].name);
    try expect(fields[0].type == .string);
    try expectEqualStrings("activo", fields[1].name);
    try expect(fields[1].type == .boolean);
    try expectEqualStrings("punto", fields[2].name);
    const punto = fields[2].type.object;
    try expect(punto.len == 2);
    try expectEqualStrings("x", punto[0].name);
    try expectInteger(punto[0].type, .number, -32768, 32767);
    try expectEqualStrings("y", punto[1].name);
    try expectInteger(punto[1].type, .bigint, -(1 << 63), (1 << 63) - 1);
}
