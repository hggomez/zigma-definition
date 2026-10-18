const zigma = @import("zigma");
const contract = @import("fixtures/concrete_entities.zig");
comptime {
    const changed = .{
        .fields = zigma.merge(.{ contract.item_def.fields, .{ .note = .{ .type = "text", .nullable = false } } }),
        .pk = contract.item_def.pk,
    };
    _ = zigma.Framework(zigma.common_type_defs, .{ .items = .{ .Type = contract.Item, .definition = changed } });
}
