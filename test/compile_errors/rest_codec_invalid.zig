const zigma = @import("zigma");
const rest = @import("zigma_rest");

const fields = zigma.record(zigma.common_type_defs, .{ .name = .{ .type = "text" } });
const entity = .{ .pk = .{"name"}, .fields = fields };
const entities = zigma.defineEntities(.{ .things = .{ .Type = zigma.Entity(zigma.common_type_defs, entity), .definition = entity } });

comptime {
    _ = rest.Api(Model, .{ .text = 42 }, .{});
}

const Model = zigma.Framework(zigma.common_type_defs, entities);
