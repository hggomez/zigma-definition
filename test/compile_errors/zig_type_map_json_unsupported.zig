//! expected: type 'f32' has no JSON mapping
const zigma = @import("zigma");
const map_json = @import("zig_type_map_json");

comptime {
    _ = map_json.jsonType(zigma.common_type_defs, @typeName(f32));
}
