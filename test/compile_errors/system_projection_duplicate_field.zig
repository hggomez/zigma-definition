const Model = @import("fixtures/model_contract.zig").Model;

comptime {
    _ = Model.Projection("things", .{ "note", "note" });
}
