const zigma = @import("zigma");
const rest = @import("zigma_rest");

const fields = zigma.record(zigma.common_type_defs, .{ .name = .{ .type = "text" } });
const entity = zigma.defineEntity(.{ .pk = .{"name"}, .fields = fields });
const entities = zigma.defineEntities(.{ .things = entity });

comptime {
    _ = rest.Api(entities, .{ .text = 42 });
}
