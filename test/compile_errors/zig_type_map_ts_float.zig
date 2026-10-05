//! expected: Zig type 'f32' has no TS mapping
const map = @import("zig_type_map_ts");

comptime {
    _ = map.tsTypeOf(f32);
}
