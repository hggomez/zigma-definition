//! expected: type 'f32' has no SQL mapping
//! A named domain whose Zig type has no mapping fails on that Zig type.
const zigma = @import("zigma");
const map_sql = @import("zig_type_map_sql");

const type_defs = zigma.defineTypes(.{
    .temperatura = zigma.TypeDef{ .Type = f32 },
});

comptime {
    _ = map_sql.sqlType(type_defs, "temperatura");
}
