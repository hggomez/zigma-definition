//! Contrato mínimo para probar el runtime sin importar AIDA.
const zigma = @import("zigma");
const options = @import("fixture_options");

const fields = if (options.extended)
    zigma.record(zigma.common_type_defs, .{
        .id = .{ .type = "integer" },
        .name = .{ .type = "text", .nullable = false },
        .note = .{ .type = "text" },
    })
else
    zigma.record(zigma.common_type_defs, .{
        .id = .{ .type = "integer" },
        .name = .{ .type = "text", .nullable = false },
    });
const definition = .{ .fields = fields, .pk = .{"id"} };
const entities = zigma.defineEntities(.{
    .products = .{
        .Type = zigma.Entity(zigma.common_type_defs, definition),
        .definition = definition,
    },
});
pub const Model = zigma.Framework(zigma.common_type_defs, entities);
