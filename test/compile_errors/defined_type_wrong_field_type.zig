//! Diagnóstico esperado: `expected type 'i64', found '*const [1:0]u8'`.
//! Una declaración tipada rechaza un campo con tipo incorrecto.
const aida = @import("aida");

comptime {
    const mal_tipado: aida.DefinedType(aida.cargo) = .{
        .cargo = "TIT",
        .denominacion = "Titular",
        .orden = "1",
        .puede_dirigir = true,
    };
    _ = mal_tipado;
}
