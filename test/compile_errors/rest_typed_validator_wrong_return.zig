const fixture = @import("fixtures/typed_validator.zig");

fn validate(_: fixture.Thing) bool {
    return true;
}

comptime {
    const invalid: fixture.Validator = .{ .validate = validate };
    _ = invalid;
}
