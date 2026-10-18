const Model = @import("fixtures/model_contract.zig").Model;

comptime {
    _ = Model.Row("missing");
}
