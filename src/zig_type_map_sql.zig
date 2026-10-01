//! Type resolution to Postgres types. All the conversion information lives
//! here, in `sql_type_defs` (keyed by `@typeName` of the Zig type); a system
//! only names its domains in its `type_defs`, which resolve through their Zig
//! type. Does not know about any concrete system.

/// The SQL type for `type_name`, resolved in this order:
/// 1. an entry in `sql_type_defs` (a Zig type name, or in the future a domain
///    with its own mapping);
/// 2. a named domain in the system's `type_defs`: a struct-backed one is the
///    composite type named after the domain, any other resolves through the
///    `@typeName` of its Zig type;
/// 3. otherwise, a compile error.
pub fn sqlType(comptime type_defs: anytype, comptime type_name: []const u8) []const u8 {
    if (@hasField(@TypeOf(sql_type_defs), type_name))
        return @field(sql_type_defs, type_name);
    if (@hasField(@TypeOf(type_defs), type_name)) {
        const T = @field(type_defs, type_name).Type;
        return switch (@typeInfo(T)) {
            .@"struct" => type_name,
            else => sqlType(type_defs, @typeName(T)),
        };
    }
    @compileError("type '" ++ type_name ++ "' has no SQL mapping");
}

/// SQL type for each supported Zig primitive type, keyed by `@typeName`.
pub const sql_type_defs = .{
    .bool = "BOOLEAN",
    .u8 = "SMALLINT",
    .i8 = "SMALLINT",
    .i16 = "SMALLINT",
    // u16 does not fit in SMALLINT (max 32767)
    .u16 = "INTEGER",
    .i32 = "INTEGER",
    .i64 = "BIGINT",
    .@"[]const u8" = "TEXT",
};
