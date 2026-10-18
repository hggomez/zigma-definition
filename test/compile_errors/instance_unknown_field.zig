//! Diagnóstico esperado: `no field named 'inexistente'`.
//! El record normalizado solo tiene los campos de la definición.
const zigma = @import("zigma");
const aida = @import("aida");

comptime {
    const cargo_info = zigma.completeRecord(aida.cargo);
    _ = cargo_info.inexistente;
}
