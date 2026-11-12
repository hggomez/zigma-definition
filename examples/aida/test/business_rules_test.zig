//! Reglas de negocio de Cargo y Docente.
const std = @import("std");
const aida = @import("aida");

test "Las instancias tipadas de Cargo ejecutan sus reglas de negocio" {
    // Declaración tipada: el literal anónimo adquiere un tipo concreto
    // mediante conversión implícita y comprobación contra el tipo declarado, acá mismo.
    const titular: aida.Cargo = .{
        .cargo = "TIT",
        .denominacion = "Titular",
        .orden = 1,
        .puede_dirigir = true,
    };
    // Una instancia válida compila y supera la validación:
    try aida.validarCargo(titular);
    // Y la lógica de validación se ejecuta sobre la instancia tipada:
    try std.testing.expectError(error.AyudanteNoPuedeDirigir, aida.validarCargo(.{
        .cargo = "AY1",
        .denominacion = "Ayudante de primera",
        .orden = 5,
        .puede_dirigir = true,
    }));
}

// Casos de negocio compartidos por la entidad concreta.
const docente_validation_cases = [_]struct {
    cargo: ?[]const u8,
    experiencia: ?i64,
    valid: bool,
}{
    .{ .cargo = "teorico", .experiencia = 4, .valid = false },
    .{ .cargo = "teorico", .experiencia = 5, .valid = true },
    .{ .cargo = "teorico", .experiencia = 6, .valid = true },
    .{ .cargo = "teorico", .experiencia = null, .valid = false },
    .{ .cargo = " \tTEORICO\r\n", .experiencia = 4, .valid = false },
    .{ .cargo = " \tTEORICO\r\n", .experiencia = 5, .valid = true },
    .{ .cargo = "practico", .experiencia = 2, .valid = true },
    .{ .cargo = "practico", .experiencia = null, .valid = true },
    .{ .cargo = null, .experiencia = null, .valid = true },
};

fn expectDocenteValidation(valid: bool, actual: aida.DocenteValidationError!void) !void {
    if (valid) {
        try actual;
    } else {
        try std.testing.expectError(error.TeoricoRequiereCincoAniosExperiencia, actual);
    }
}

test "La validación del docente recibe todos los campos y conserva las reglas de experiencia con nacimiento válido" {
    const validate: *const fn (aida.Docente, aida.Fecha) aida.DocenteValidationError!void = aida.validarDocente;
    for (docente_validation_cases) |case| {
        // Docente exige la fila completa, incluso los campos ajenos a la regla.
        var row: aida.Docente = .{
            .docente = "d1",
            .apellido = null,
            .nombres = "Ada",
            .cargo = case.cargo,
            .email = null,
            .email_alternativo = null,
            .jefe = null,
            .telefono = null,
            .experiencia = case.experiencia,
            .esImportador = null,
            .fecha_nacimiento = .{ .@"año" = 1980, .mes = 1, .@"día" = 1 },
        };
        try expectDocenteValidation(case.valid, validate(row, .{ .@"año" = 2026, .mes = 10, .@"día" = 28 }));

        row.nombres = "Grace";
        row.telefono = "555-0100";
        row.esImportador = true;
        try expectDocenteValidation(case.valid, validate(row, .{ .@"año" = 2026, .mes = 10, .@"día" = 28 }));
    }
}
