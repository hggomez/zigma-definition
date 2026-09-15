//! Diagnóstico esperado: `type 'fecha': must be a TypeDef`.
//! También se rechaza un struct que no tenga exactamente la forma de TypeDef.
const zigma = @import("zigma");

comptime {
    _ = zigma.defineTypes(.{ .fecha = .{ .Type = f64, .extra = true } });
}
