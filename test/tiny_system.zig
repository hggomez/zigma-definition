//! Minimal system used to prove generators consume Infos without knowing aida.
//! Required `system` shape: `type_defs` and `entity_defs`.

const zigma = @import("zigma");

pub const type_defs = zigma.defineTypes(zigma.common_type_defs);

pub const item = zigma.record(type_defs, .{
    .id = .{ .type = "text" },
    .nombre = .{ .type = "text" },
});

pub const items = zigma.defineEntity(.{
    .pk = .{"id"},
    .fields = item,
});

pub const entity_defs = zigma.defineEntities(.{
    .items = items,
});
