//! Diagnóstico esperado: `uk field 'inexistente' is not a field`.
const zigma = @import("zigma");
const aida = @import("aida");

comptime {
    _ = zigma.defineEntity(.{
        .pk = .{"materia"},
        .uks = .{ .u = .{"inexistente"} },
        .fields = aida.materia,
    });
}
