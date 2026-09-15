const zigma = @import("zigma");

comptime {
    _ = zigma.System(
        .{ .optional_integer = .{ .Type = ?i64 } },
        .{ .things = zigma.defineEntity(.{
            .pk = .{"id"},
            .fields = .{ .id = .{ .type = "optional_integer" } },
        }) },
    );
}
