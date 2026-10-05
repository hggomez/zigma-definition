//! Contrato de prueba cuyo catálogo excede los 32768 bytes del frontend.
const zigma = @import("zigma");

const long_label = blk: {
    var bytes: [40000]u8 = undefined;
    @memset(&bytes, 'a');
    break :blk bytes;
};

pub const type_defs = zigma.common_type_defs;
const item_def = .{
    .fields = zigma.record(type_defs, .{
        .id = .{ .type = "text", .label = &long_label },
    }),
    .pk = .{"id"},
};
pub const entity_defs = .{
    .items = .{ .Type = zigma.Entity(type_defs, item_def), .definition = item_def },
};
