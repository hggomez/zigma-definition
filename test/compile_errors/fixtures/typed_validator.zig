//! El factory vive en el fixture para distinguir su ausencia de una firma inválida.
const rest = @import("zigma_rest");
const contract = @import("model_contract.zig");
pub const Model = contract.Model;
pub const Thing = Model.Row("things");
pub const Validator = rest.BusinessValidator(Thing);
