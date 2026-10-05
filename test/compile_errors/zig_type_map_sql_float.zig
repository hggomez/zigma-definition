//! expected: Zig type 'f32' has no SQL mapping
const map = @import("zig_type_map_sql");

comptime {
    _ = map.sqlTypeOf(f32);
}
