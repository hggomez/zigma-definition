//! expected: type 'f32' has no TS mapping
const map_ts = @import("zig_type_map_ts");

comptime {
    _ = map_ts.tsType(map_ts.primitive_ts_types, @typeName(f32));
}
