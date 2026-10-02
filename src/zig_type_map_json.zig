//! Type resolution to JSON: how each Zig type travels in JSON, for the
//! generated TS code to convert data to and from JSON. All the conversion
//! information lives here, in `json_type_defs` (keyed by `@typeName` of the
//! Zig type); a system only names its domains in its `type_defs`, which
//! resolve through their Zig type. Does not know about any concrete system.
//!
//! Like `ts_parser_defs` for pg, the runtime conversion is done by
//! `JSON.parse` / `JSON.stringify`; an entry only carries TS expressions for
//! the types they cannot handle as is:
//! * `encode`: over `v`, the TS value, what `JSON.stringify` must see instead;
//! * `decode`: over `source`, the original JSON text of the value, the TS
//!   value (`JSON.parse` gives its reviver that text as `context.source`).

/// JSON type, and the encode/decode when needed, for each supported Zig
/// primitive type, keyed by `@typeName`.
pub const json_type_defs = .{
    .bool = .{ .json = "boolean" },
    .u8 = .{ .json = "number" },
    .i8 = .{ .json = "number" },
    .i16 = .{ .json = "number" },
    .u16 = .{ .json = "number" },
    .i32 = .{ .json = "number" },
    // a bigint in TS: JSON.stringify throws on it, and JSON.parse rounds a
    // number past 2^53
    .i64 = .{ .json = "number", .encode = "JSON.rawJSON(v.toString())", .decode = "BigInt(source)" },
    .@"[]const u8" = .{ .json = "string" },
};

// Every function below resolves a type name in the same order as `sqlType` /
// `tsType`:
// 1. an entry in `json_type_defs` (a Zig type name);
// 2. a named domain in the system's `type_defs`, through its Zig type: a
//    struct is a JSON object, converted field by field by the generator;
// 3. otherwise, a compile error.
// (Each one recurses on its own comptime parameters instead of sharing a
// resolver: a helper's return value is not comptime-known from a runtime
// caller, so it could not feed the `@field` lookups.)

/// The JSON type of the value: "boolean", "number", "string" or "object".
pub fn jsonType(comptime type_defs: anytype, comptime type_name: []const u8) []const u8 {
    if (@hasField(@TypeOf(json_type_defs), type_name))
        return @field(json_type_defs, type_name).json;
    if (@hasField(@TypeOf(type_defs), type_name)) {
        const T = @field(type_defs, type_name).Type;
        return switch (@typeInfo(T)) {
            .@"struct" => "object",
            else => jsonType(type_defs, @typeName(T)),
        };
    }
    @compileError("type '" ++ type_name ++ "' has no JSON mapping");
}

/// The TS expression over `v` that `JSON.stringify` must see instead of the
/// value, or null when it goes as is.
pub fn jsonEncode(comptime type_defs: anytype, comptime type_name: []const u8) ?[]const u8 {
    return optionalProperty(type_defs, type_name, "encode");
}

/// The TS expression over `source` (the original JSON text) giving the TS
/// value, or null when `JSON.parse`'s value is already right.
pub fn jsonDecode(comptime type_defs: anytype, comptime type_name: []const u8) ?[]const u8 {
    return optionalProperty(type_defs, type_name, "decode");
}

fn optionalProperty(comptime type_defs: anytype, comptime type_name: []const u8, comptime property: []const u8) ?[]const u8 {
    if (@hasField(@TypeOf(json_type_defs), type_name)) {
        const Entry = @TypeOf(@field(json_type_defs, type_name));
        return if (@hasField(Entry, property)) @field(@field(json_type_defs, type_name), property) else null;
    }
    if (@hasField(@TypeOf(type_defs), type_name)) {
        const T = @field(type_defs, type_name).Type;
        return switch (@typeInfo(T)) {
            .@"struct" => null,
            else => optionalProperty(type_defs, @typeName(T), property),
        };
    }
    @compileError("type '" ++ type_name ++ "' has no JSON mapping");
}
