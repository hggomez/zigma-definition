const Item = @import("fixtures/concrete_entities.zig").Item;
comptime {
    const value: Item = .{ .id = null, .label = "Ada", .note = null };
    _ = value;
}
