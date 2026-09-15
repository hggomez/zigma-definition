//! Diagnóstico esperado: `pk field 'inexistente' is not a field`.
//! También se rechaza una clave incorrecta entre otras válidas.
const zigma = @import("zigma");
const aida = @import("aida");

comptime {
    _ = zigma.defineEntity(.{ .pk = .{ "materia", "inexistente" }, .fields = aida.materia });
}
