const zigma = @import("zigma");
comptime {
    _ = zigma.Entity(zigma.common_type_defs, .{
        .fields = .{ .id = .{ .type = "missing" } },
        .pk = .{"id"},
    });
}
