const zigma = @import("zigma");
const contract = @import("fixtures/concrete_entities.zig");
comptime {
    const types = zigma.merge(.{ zigma.common_type_defs, .{ .integer = zigma.TypeDef{ .Type = u32 } } });
    _ = zigma.Framework(types, .{ .items = .{ .Type = contract.Item, .definition = contract.item_def } });
}
