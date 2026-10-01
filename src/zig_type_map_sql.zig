//! Type name -> Postgres type lookup, plus the framework's map for Zig
//! primitive types. Does not know about any concrete system.

/// The SQL type for `type_name` in `sql_types`: a struct whose field names are
/// type names and whose values are SQL types. The same lookup serves a
/// system's domain map (`aida.sql_type_defs`, keyed by domain type name) and
/// the primitive map below (keyed by `@typeName` of the Zig type).
pub fn sqlType(comptime sql_types: anytype, comptime type_name: []const u8) []const u8 {
    if (!@hasField(@TypeOf(sql_types), type_name))
        @compileError("type '" ++ type_name ++ "' has no SQL mapping");
    return @field(sql_types, type_name);
}

/// SQL type for each supported Zig primitive type, keyed by `@typeName`. Used
/// for the leaf fields of struct-backed domain types (e.g. `aida.Fecha`), whose
/// fields are Zig types, not domain types.
pub const primitive_sql_types = .{
    .bool = "BOOLEAN",
    .u8 = "SMALLINT",
    .i8 = "SMALLINT",
    .i16 = "SMALLINT",
    // u16 does not fit in SMALLINT (max 32767)
    .u16 = "INTEGER",
    .i32 = "INTEGER",
    .@"[]const u8" = "TEXT",
};
