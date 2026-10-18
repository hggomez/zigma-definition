const Item = @import("fixtures/concrete_entities.zig").Item;
comptime {
    const value: Item = .{ .id = true, .label = "Ada", .note = null };
    _ = value;
}
