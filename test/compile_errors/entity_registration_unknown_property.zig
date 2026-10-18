const zigma = @import("zigma");
const contract = @import("fixtures/concrete_entities.zig");
comptime {
    _ = zigma.defineEntities(.{ .items = .{
        .Type = struct { id: i64 },
        .definition = contract.item_def,
        .extra = true,
    } });
}
