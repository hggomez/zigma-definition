//! Type resolution to TypeScript types. All the conversion information lives
//! here, in `ts_type_defs` (keyed by `@typeName` of the Zig type); a system
//! only names its domains in its `type_defs`, which resolve through their Zig
//! type. Does not know about any concrete system.

/// The TS type for `type_name`, resolved in this order:
/// 1. an entry in `ts_type_defs` (a Zig type name, or in the future a domain
///    with its own mapping);
/// 2. a named domain in the system's `type_defs`, through its Zig type: a
///    struct is an inline object type, one member per field;
/// 3. otherwise, a compile error.
pub fn tsType(comptime type_defs: anytype, comptime type_name: []const u8) []const u8 {
    if (@hasField(@TypeOf(ts_type_defs), type_name))
        return @field(ts_type_defs, type_name);
    if (@hasField(@TypeOf(type_defs), type_name))
        return tsTypeOfZig(type_defs, @field(type_defs, type_name).Type);
    @compileError("type '" ++ type_name ++ "' has no TS mapping");
}

fn tsTypeOfZig(comptime type_defs: anytype, comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .@"struct" => ObjectType(type_defs, T).ts,
        else => tsType(type_defs, @typeName(T)),
    };
}

/// The inline object type of a struct, built in a container-level const so it
/// is always evaluated in comptime scope (the members' types come from calls,
/// which would not be comptime-known from a runtime caller; see `LabelHolder`
/// in zigma.zig for the same trick).
fn ObjectType(comptime type_defs: anytype, comptime T: type) type {
    return struct {
        pub const ts = blk: {
            const info = @typeInfo(T).@"struct";
            var out: []const u8 = "{ ";
            for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
                if (i > 0) out = out ++ "; ";
                out = out ++ field_name ++ ": " ++ tsTypeOfZig(type_defs, field_type);
            }
            break :blk out ++ " }";
        };
    };
}

/// TS type for each supported Zig primitive type, keyed by `@typeName`.
/// `i64` is `bigint`: pg returns BIGINT as a string by default, so the backend
/// registers `pg.types.setTypeParser(20, BigInt)`.
pub const ts_type_defs = .{
    .bool = "boolean",
    .u8 = "number",
    .i8 = "number",
    .i16 = "number",
    .u16 = "number",
    .i32 = "number",
    .i64 = "bigint",
    .@"[]const u8" = "string",
};
