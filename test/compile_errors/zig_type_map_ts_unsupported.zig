//! expected: type 'f32' has no TS mapping
const zigma = @import("zigma");
const map_ts = @import("zig_type_map_ts");

comptime {
    _ = map_ts.tsType(zigma.common_type_defs, @typeName(f32));
}
