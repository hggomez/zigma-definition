const aida = @import("aida");

test "cargo validation does not activate when puede_dirigir is null" {
    try aida.validarCargo(.{
        .cargo = "AY1",
        .denominacion = "Ayudante de primera",
        .orden = 5,
        .puede_dirigir = null,
    });
}

test "cargo validation accepts a missing denomination even when puede_dirigir is true" {
    try aida.validarCargo(.{
        .cargo = "AY1",
        .denominacion = null,
        .orden = 5,
        .puede_dirigir = true,
    });
}
