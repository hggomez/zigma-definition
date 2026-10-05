const rest = @import("zigma_rest");
const contract = @import("fixtures/model_contract.zig");

// Misma forma que la entidad, distinta identidad: no es el tipo registrado.
const Manual = struct { tenant: []const u8, id: i64, name: []const u8, note: ?[]const u8, active: bool };
fn validate(_: Manual) ?rest.BusinessRuleViolation {
    return null;
}

comptime {
    _ = rest.defineBusinessValidators(contract.Model, .{
        .things = rest.BusinessValidator(Manual){ .validate = validate },
    });
}
