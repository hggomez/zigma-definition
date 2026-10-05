const Item = @import("fixtures/concrete_entities.zig").Item;
comptime {
    const value: Item = .{ .id = 1, .note = null };
    _ = value;
}
