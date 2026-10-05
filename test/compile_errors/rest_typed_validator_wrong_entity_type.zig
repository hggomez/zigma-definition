const rest = @import("zigma_rest");
const contract = @import("fixtures/model_contract.zig");

fn validate(_: contract.Model.Row("parents")) ?rest.BusinessRuleViolation {
    return null;
}

comptime {
    _ = rest.defineBusinessValidators(contract.Model, .{
        .things = rest.BusinessValidator(contract.Model.Row("parents")){ .validate = validate },
    });
}
