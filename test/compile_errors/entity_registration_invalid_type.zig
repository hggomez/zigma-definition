const zigma = @import("zigma");
const contract = @import("fixtures/concrete_entities.zig");
comptime {
    _ = zigma.defineEntities(.{ .items = .{ .Type = 42, .definition = contract.item_def } });
}
