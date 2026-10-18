//! Diagnóstico esperado: `expected type 'i64'`.
//! El tipo de instancia tiene tipado estricto: no se puede asignar un string
//! a un campo entero.
const zigma = @import("zigma");
const aida = @import("aida");

comptime {
    const Cargo = zigma.RecordInstanceType(aida.type_defs, aida.cargo);
    const bad: Cargo = .{
        .cargo = "JTP",
        .denominacion = "Jefe de Trabajos Prácticos",
        .orden = "cuatro",
        .puede_dirigir = true,
    };
    _ = bad;
}
