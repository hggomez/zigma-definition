//! expected: type 'f32' has no SQL mapping
const zigma = @import("zigma");
const map_sql = @import("zig_type_map_sql");

comptime {
    _ = map_sql.sqlType(zigma.common_type_defs, @typeName(f32));
}
