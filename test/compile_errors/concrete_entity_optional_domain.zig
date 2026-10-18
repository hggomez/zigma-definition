const zigma = @import("zigma");
// No pasa por defineTypes ni por record ni por Framework.
comptime {
    _ = zigma.Entity(.{ .optional_integer = zigma.TypeDef{ .Type = ?i64 } }, .{
        .fields = .{ .id = .{ .type = "optional_integer" } },
        .pk = .{"id"},
    });
}
