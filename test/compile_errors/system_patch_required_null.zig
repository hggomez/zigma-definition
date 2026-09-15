const Model = @import("fixtures/model_contract.zig").Model;

comptime {
    const patch: Model.Patch("things") = .{ .active = .{ .set = null } };
    _ = patch;
}
