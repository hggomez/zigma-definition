//! Diagnóstico esperado: `pk field 'inexistente' is not a field`.
const zigma = @import("zigma");
const aida = @import("aida");

comptime {
    _ = zigma.defineEntity(.{ .pk = .{"inexistente"}, .fields = aida.materia });
}
