//! Sin reglas con contexto: el servidor debe usar EmptyContextProvider.
const rest = @import("zigma_rest");
const contract = @import("contract");

pub const Api = rest.Api(contract.Model, rest.common_codecs, .{});
