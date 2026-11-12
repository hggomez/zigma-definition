const aida = @import("aida");

test "La validación de Cargo no se activa cuando puede_dirigir es nulo" {
    try aida.validarCargo(.{
        .cargo = "AY1",
        .denominacion = "Ayudante de primera",
        .orden = 5,
        .puede_dirigir = null,
    });
}

test "La validación de Cargo acepta una denominación ausente aunque pueda dirigir" {
    try aida.validarCargo(.{
        .cargo = "AY1",
        .denominacion = null,
        .orden = 5,
        .puede_dirigir = true,
    });
}
