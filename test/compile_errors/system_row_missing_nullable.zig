const Model = @import("fixtures/model_contract.zig").Model;

comptime {
    const row: Model.Row("things") = .{ .tenant = "acme", .id = 7, .name = "Ada", .active = true };
    _ = row;
}
