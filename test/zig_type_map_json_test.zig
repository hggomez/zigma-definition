//! Tests for the type resolution of `zig_type_map_json`: how each Zig type
//! travels in JSON, for the generated TS code to convert data to and from
//! JSON (the role `ts_parser_defs` / `pgTypes` play for pg). All the
//! conversion information lives in the framework's `json_type_defs` (keyed by
//! `@typeName` of the Zig type); a system only names its domains in
//! `type_defs`, which resolve through their Zig type. The unmapped cases are
//! "does not compile" cases (test/compile_errors/zig_type_map_json_*).
//!
//! * `jsonType`: the JSON type of the value ("boolean", "number", "string",
//!   "object").
//! * `jsonEncode`: a TS expression over `v` (the TS value) giving what
//!   `JSON.stringify` must see instead, or null when `v` goes as is.
//! * `jsonDecode`: a TS expression over `source` (the original JSON text of
//!   the value) giving the TS value, or null when `JSON.parse`'s value is
//!   already right.
//!
//! A struct is an "object" converted field by field by the generator: at its
//! own level it has no encode/decode.

const std = @import("std");
const zigma = @import("zigma");
const map_json = @import("zig_type_map_json");
const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

const Punto = struct { x: i16, y: u16 };

/// A minimal system: the framework's common types plus an alias of a
/// primitive (`email`) and a struct-backed domain (`punto`).
const type_defs = zigma.defineTypes(zigma.merge(.{ zigma.common_type_defs, .{
    .email = zigma.common_type_defs.text,
    .punto = zigma.TypeDef{ .Type = Punto },
} }));

fn jsonTypeOf(comptime T: type) []const u8 {
    return map_json.jsonType(type_defs, @typeName(T));
}

fn expectAsIs(comptime T: type) !void {
    try expect(map_json.jsonEncode(type_defs, @typeName(T)) == null);
    try expect(map_json.jsonDecode(type_defs, @typeName(T)) == null);
}

// ---- Zig primitives, by @typeName ----

test "bool is a JSON boolean, as is" {
    try expectEqualStrings("boolean", jsonTypeOf(bool));
    try expectAsIs(bool);
}

test "integers that fit in a JS number are a JSON number, as is" {
    inline for (.{ u8, i8, i16, u16, i32 }) |T| {
        try expectEqualStrings("number", jsonTypeOf(T));
        try expectAsIs(T);
    }
}

test "i64 is a JSON number, sent and read exactly as a bigint" {
    // JSON.stringify throws on a bigint, and JSON.parse rounds a number past
    // 2^53: the bigint goes out as its exact digits, and comes back from the
    // original text of the number.
    try expectEqualStrings("number", jsonTypeOf(i64));
    try expectEqualStrings("JSON.rawJSON(v.toString())", map_json.jsonEncode(type_defs, @typeName(i64)).?);
    try expectEqualStrings("BigInt(source)", map_json.jsonDecode(type_defs, @typeName(i64)).?);
}

test "a byte slice is a JSON string, as is" {
    try expectEqualStrings("string", jsonTypeOf([]const u8));
    try expectAsIs([]const u8);
}

// ---- named domains, resolved through their Zig type ----

test "a common domain resolves through its Zig type" {
    try expectEqualStrings("string", map_json.jsonType(type_defs, "text"));
    try expectEqualStrings("number", map_json.jsonType(type_defs, "integer"));
    try expectEqualStrings("boolean", map_json.jsonType(type_defs, "boolean"));
    try expectEqualStrings("BigInt(source)", map_json.jsonDecode(type_defs, "integer").?);
    try expect(map_json.jsonDecode(type_defs, "text") == null);
}

test "a system domain aliasing a primitive keeps its name and resolves through its Zig type" {
    try expectEqualStrings("string", map_json.jsonType(type_defs, "email"));
    try expect(map_json.jsonEncode(type_defs, "email") == null);
}

test "a struct-backed domain is a JSON object, converted field by field" {
    try expectEqualStrings("object", map_json.jsonType(type_defs, "punto"));
    try expect(map_json.jsonEncode(type_defs, "punto") == null);
    try expect(map_json.jsonDecode(type_defs, "punto") == null);
}
