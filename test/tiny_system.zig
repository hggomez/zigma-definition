//! Contrato mínimo para probar generadores que no conocen AIDA.
//! El módulo system expone type_defs y el registro entity_defs.

const zigma = @import("zigma");

pub const type_defs = zigma.defineTypes(zigma.common_type_defs);

pub const item = zigma.record(type_defs, .{
    .id = .{ .type = "text" },
    .nombre = .{ .type = "text" },
});

pub const item_def = .{
    .pk = .{"id"},
    .fields = item,
};

pub const Item = zigma.Entity(type_defs, item_def);

pub const entity_defs = zigma.defineEntities(.{
    .items = .{ .Type = Item, .definition = item_def },
});
