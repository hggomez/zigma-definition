const rest = @import("zigma_rest");
const fixture = @import("fixtures/contextual_validators.zig");
// La firma no coincide con el contexto declarado, aunque el resto de la forma sí.
const Invalid = struct {
    pub const Context = fixture.Context;
    validate: *const fn (fixture.Row, fixture.OtherContext) ?rest.BusinessRuleViolation,
};
fn validate(_: fixture.Row, _: fixture.OtherContext) ?rest.BusinessRuleViolation {
    return null;
}
comptime {
    _ = rest.defineBusinessValidators(fixture.Model, .{ .firsts = Invalid{ .validate = validate } });
}
