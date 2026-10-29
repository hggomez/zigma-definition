const rest = @import("zigma_rest");
const fixture = @import("fixtures/contextual_validators.zig");
const Manual = struct { id: i64 };
fn validate(_: Manual, _: fixture.Context) ?rest.BusinessRuleViolation {
    return null;
}
comptime {
    _ = rest.defineBusinessValidators(fixture.Model, .{
        .firsts = rest.BusinessValidator(Manual, fixture.Context){ .validate = validate },
    });
}
