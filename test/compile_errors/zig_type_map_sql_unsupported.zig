//! expected: type 'f32' has no SQL mapping
const map_sql = @import("zig_type_map_sql");

comptime {
    _ = map_sql.sqlType(map_sql.primitive_sql_types, @typeName(f32));
}
