const zigma = @import("zigma");
comptime {
    const definition = .{
        .fields = .{ .id = .{ .type = "integer" } },
        .pk = .{"id"},
        .fks = .{ .parent = .{ .entity = "missing", .fields = .{"id"} } },
    };
    const Item = zigma.Entity(zigma.common_type_defs, definition);
    _ = zigma.Framework(zigma.common_type_defs, .{ .items = .{ .Type = Item, .definition = definition } });
}
