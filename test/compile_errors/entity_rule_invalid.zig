const zigma = @import("zigma");
const contract = @import("fixtures/model_contract.zig");

comptime {
    _ = zigma.Entity(zigma.common_type_defs, .{
        .pk = .{"id"},
        .fields = contract.fields,
        .rules = .{ .display = 42 },
    });
}
