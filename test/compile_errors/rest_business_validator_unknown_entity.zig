const zigma = @import("zigma");
const rest = @import("zigma_rest");

const fields = zigma.record(zigma.common_type_defs, .{
    .id = .{ .type = "integer" },
});
const entities = zigma.defineEntities(.{
    .things = zigma.defineEntity(.{ .pk = .{"id"}, .fields = fields }),
});

const invalid = rest.defineBusinessValidators(Model, .{
    .missing = 42,
});

comptime {
    _ = invalid;
}

const Model = zigma.System(zigma.common_type_defs, entities);
