const zigma = @import("zigma");
const contract = @import("fixtures/model_contract.zig");

comptime {
    _ = zigma.defineEntity(.{
        .pk = .{"id"},
        .fields = contract.fields,
        .rules = .{ .display = .{ .fields = .{"note"}, .field = "note" } },
    });
}
