//! Contrato compartido de los tests del modelo normalizado, sin implementaciones de aplicación.
const zigma = @import("zigma");

pub const fields = zigma.record(zigma.common_type_defs, .{
    .tenant = .{ .type = "text" },
    .id = .{ .type = "integer", .nullable = true },
    .name = .{ .type = "text", .nullable = false },
    .note = .{ .type = "text" },
    .active = .{ .type = "boolean", .nullable = false },
});

pub const things = .{
    .pk = .{ "tenant", "id", "id" },
    .fields = fields,
    .fks = .{
        .parent = .{ .entity = "parents", .fields = .{ "tenant", "id" } },
    },
};

const parents = .{
    .pk = .{ "tenant", "id" },
    .fields = zigma.record(zigma.common_type_defs, .{
        .tenant = .{ .type = "text" },
        .id = .{ .type = "integer" },
    }),
};

pub const entities = zigma.defineEntities(.{
    .parents = .{ .Type = zigma.Entity(zigma.common_type_defs, parents), .definition = parents },
    .things = .{ .Type = zigma.Entity(zigma.common_type_defs, things), .definition = things },
});

pub const Model = zigma.Framework(zigma.common_type_defs, entities);
