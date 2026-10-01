//! Type name -> TypeScript type lookup, plus the framework's map for Zig
//! primitive types. Does not know about any concrete system.

/// The TS type for `type_name` in `ts_types`: a struct whose field names are
/// type names and whose values are TS types. The same lookup serves a
/// system's domain map (`aida.ts_type_defs`, keyed by domain type name) and
/// the primitive map below (keyed by `@typeName` of the Zig type).
pub fn tsType(comptime ts_types: anytype, comptime type_name: []const u8) []const u8 {
    if (!@hasField(@TypeOf(ts_types), type_name))
        @compileError("type '" ++ type_name ++ "' has no TS mapping");
    return @field(ts_types, type_name);
}

/// TS type for each supported Zig primitive type, keyed by `@typeName`. Used
/// for the leaf fields of struct-backed domain types (e.g. `aida.Fecha`), whose
/// fields are Zig types, not domain types.
pub const primitive_ts_types = .{
    .bool = "boolean",
    .u8 = "number",
    .i8 = "number",
    .i16 = "number",
    .u16 = "number",
    .i32 = "number",
    .@"[]const u8" = "string",
};
