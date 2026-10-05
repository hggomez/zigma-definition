const rest = @import("zigma_rest");
const fixture = @import("fixtures/typed_validator.zig");

fn validate(_: []const rest.FieldValue) ?rest.BusinessRuleViolation {
    return null;
}

comptime {
    const invalid: fixture.Validator = .{ .validate = validate };
    _ = invalid;
}
