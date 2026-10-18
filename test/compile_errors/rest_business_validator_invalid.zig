const zigma = @import("zigma");
const rest = @import("zigma_rest");

const fields = zigma.record(zigma.common_type_defs, .{
    .id = .{ .type = "integer" },
});
const definition = .{ .pk = .{"id"}, .fields = fields };
const entities = zigma.defineEntities(.{
    .things = .{ .Type = zigma.Entity(zigma.common_type_defs, definition), .definition = definition },
});

const invalid = rest.defineBusinessValidators(Model, .{
    .things = .{ .validate = 42 },
});

comptime {
    _ = invalid;
}

const Model = zigma.Framework(zigma.common_type_defs, entities);
