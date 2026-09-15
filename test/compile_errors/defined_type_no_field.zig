//! Se espera un error en el acceso siguiente: no se puede acceder
//! a campos que no pertenecen a la definición.
const aida = @import("aida");

comptime {
    const titular: aida.DefinedType(aida.cargo) = .{
        .cargo = "TIT",
        .denominacion = "Titular",
        .orden = 1,
        .puede_dirigir = true,
    };
    _ = titular.inexistente;
}
