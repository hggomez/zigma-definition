//! Se espera un error en la llamada siguiente por un campo faltante:
//! no se aporta puede_dirigir y el tipo de instancia no tiene defaults.
const aida = @import("aida");

comptime {
    _ = aida.validarCargo(.{ .cargo = "ADJ", .denominacion = "Adjunto", .orden = 2 });
}
