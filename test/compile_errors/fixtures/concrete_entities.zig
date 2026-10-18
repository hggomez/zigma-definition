//! Contratos de la API de entidades concretas; no dependen de AIDA.
const zigma = @import("zigma");

pub const Stamp = struct { tick: i64 };
pub const type_defs = zigma.defineTypes(zigma.merge(.{ zigma.common_type_defs, .{
    .stamp = zigma.TypeDef{ .Type = Stamp },
} }));

pub const fields = zigma.record(type_defs, .{
    .tenant = .{ .type = "text", .label = "Organización" },
    .id = .{ .type = "integer", .nullable = true, .description = "Identificador local" },
    .label = .{ .type = "text", .nullable = false },
    .note = .{ .type = "text" },
    .enabled = .{ .type = "boolean", .nullable = false },
    .stamp = .{ .type = "stamp" },
});

pub const thing_def = .{
    .fields = fields,
    .pk = .{ "tenant", "id", "id" },
    .fks = .{ .parent = .{ .entity = "things", .fields = .{ "tenant", "id" } } },
    .uks = .{ .by_label = .{"label"} },
    .rules = .{ .display = .{ .fields = .{ "note", "label" } } },
};
pub const Thing = zigma.Entity(type_defs, thing_def);
pub const registrations = zigma.defineEntities(.{
    .things = .{ .Type = Thing, .definition = thing_def },
});
pub const Model = zigma.Framework(type_defs, registrations);

pub const item_def = .{
    .fields = .{
        .id = .{ .type = "integer" },
        .label = .{ .type = "text", .nullable = false },
        .note = .{ .type = "text" },
    },
    .pk = .{"id"},
};
pub const Item = zigma.Entity(zigma.common_type_defs, item_def);

// Ciclo entre entidades diferentes: la ida usa una UK y la vuelta una PK.
pub const left_def = .{
    .fields = .{
        .id = .{ .type = "integer" },
        .right_code = .{ .type = "text" },
    },
    .pk = .{"id"},
    .fks = .{ .right = .{ .entity = "rights", .fields = .{ .right_code = "code" } } },
};
pub const right_def = .{
    .fields = .{
        .id = .{ .type = "integer" },
        .code = .{ .type = "text", .nullable = false },
        .left_id = .{ .type = "integer" },
    },
    .pk = .{"id"},
    .uks = .{ .by_code = .{"code"} },
    .fks = .{ .left = .{ .entity = "lefts", .fields = .{ .left_id = "id" } } },
};
pub const Left = zigma.Entity(zigma.common_type_defs, left_def);
pub const Right = zigma.Entity(zigma.common_type_defs, right_def);
pub const circular_registrations = zigma.defineEntities(.{
    .lefts = .{ .Type = Left, .definition = left_def },
    .rights = .{ .Type = Right, .definition = right_def },
});
pub const CircularModel = zigma.Framework(zigma.common_type_defs, circular_registrations);
