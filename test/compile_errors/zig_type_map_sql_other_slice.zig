//! expected: Zig type '[]const i32' has no SQL mapping
//! (only []const u8 is TEXT)
const map = @import("zig_type_map_sql");

comptime {
    _ = map.sqlTypeOf([]const i32);
}
