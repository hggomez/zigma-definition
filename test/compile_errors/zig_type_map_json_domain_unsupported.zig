//! expected: type 'f32' has no JSON mapping
//! A named domain whose Zig type has no mapping fails on that Zig type.
const zigma = @import("zigma");
const map_json = @import("zig_type_map_json");

const type_defs = zigma.defineTypes(.{
    .temperatura = zigma.TypeDef{ .Type = f32 },
});

comptime {
    _ = map_json.jsonDecode(type_defs, "temperatura");
}
