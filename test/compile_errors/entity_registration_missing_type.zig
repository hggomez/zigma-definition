const zigma = @import("zigma");
const contract = @import("fixtures/concrete_entities.zig");
comptime {
    _ = zigma.defineEntities(.{ .items = .{ .definition = contract.item_def } });
}
