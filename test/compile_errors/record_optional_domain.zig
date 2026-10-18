const zigma = @import("zigma");

comptime {
    _ = zigma.RecordInstanceType(
        .{ .optional_integer = .{ .Type = ?i64 } },
        .{ .value = .{ .type = "optional_integer", .nullable = false } },
    );
}
