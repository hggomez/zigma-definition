//! expected: Zig type '[]const i32' has no TS mapping
//! (only []const u8 is a string)
const map = @import("zig_type_map_ts");

comptime {
    _ = map.tsTypeOf([]const i32);
}
