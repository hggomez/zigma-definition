//! Contrato compartido de los tests del modelo normalizado, sin implementaciones de aplicación.
const zigma = @import("zigma");

pub const fields = zigma.record(zigma.common_type_defs, .{
    .tenant = .{ .type = "text" },
    .id = .{ .type = "integer", .nullable = true },
    .name = .{ .type = "text", .nullable = false },
    .note = .{ .type = "text" },
    .active = .{ .type = "boolean", .nullable = false },
});

pub const things = zigma.defineEntity(.{
    .pk = .{ "tenant", "id", "id" },
    .fields = fields,
    .fks = .{
        .parent = .{ .entity = "parents", .fields = .{ "tenant", "id" } },
    },
});

pub const entities = zigma.defineEntities(.{
    .parents = zigma.defineEntity(.{
        .pk = .{ "tenant", "id" },
        .fields = zigma.record(zigma.common_type_defs, .{
            .tenant = .{ .type = "text" },
            .id = .{ .type = "integer" },
        }),
    }),
    .things = things,
});

pub const Model = zigma.System(zigma.common_type_defs, entities);
