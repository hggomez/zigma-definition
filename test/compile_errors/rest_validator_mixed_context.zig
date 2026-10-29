const rest = @import("zigma_rest");
const fixture = @import("fixtures/contextual_validators.zig");
fn first(_: fixture.Row, _: fixture.Context) ?rest.BusinessRuleViolation {
    return null;
}
fn second(_: fixture.Row, _: fixture.OtherContext) ?rest.BusinessRuleViolation {
    return null;
}
comptime {
    _ = rest.defineBusinessValidators(fixture.Model, .{
        .firsts = rest.BusinessValidator(fixture.Row, fixture.Context){ .validate = first },
        .seconds = rest.BusinessValidator(fixture.Row, fixture.OtherContext){ .validate = second },
    });
}
