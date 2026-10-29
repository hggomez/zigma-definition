//! Edad civil y reglas de docente con una fecha de referencia explícita.
const std = @import("std");
const aida = @import("aida");
const expect = std.testing.expect;

fn date(year: u16, month: u8, day: u8) aida.Fecha {
    return .{ .@"año" = year, .mes = month, .@"día" = day };
}

const today = date(2026, 10, 28);

fn docente(birth: ?aida.Fecha) aida.Docente {
    return .{
        .docente = "d1",
        .apellido = null,
        .nombres = "Ada",
        .cargo = "teorico",
        .email = null,
        .email_alternativo = null,
        .jefe = null,
        .telefono = null,
        .experiencia = 5,
        .esImportador = null,
        .fecha_nacimiento = birth,
    };
}

test "ageOn counts completed birthdays rather than elapsed calendar years" {
    try expect(try date(1996, 10, 28).ageOn(date(2026, 10, 27)) == 29);
    try expect(try date(1996, 10, 28).ageOn(today) == 30);
    try expect(try date(1996, 10, 28).ageOn(date(2026, 10, 29)) == 30);
    try expect(try date(1996, 12, 31).ageOn(date(2026, 1, 1)) == 29);
    try expect(try today.ageOn(today) == 0);
    try expect(try date(1, 1, 1).ageOn(date(9999, 12, 31)) == 9998);
}

test "February 29 birthdays fall on March 1 in non leap years" {
    const birth = date(2000, 2, 29);
    try expect(try birth.ageOn(date(2030, 2, 28)) == 29);
    try expect(try birth.ageOn(date(2030, 3, 1)) == 30);
    try expect(try birth.ageOn(date(2028, 2, 28)) == 27);
    try expect(try birth.ageOn(date(2028, 2, 29)) == 28);
    try expect(try birth.ageOn(date(2100, 2, 28)) == 99);
    try expect(try birth.ageOn(date(2100, 3, 1)) == 100);
}

test "ageOn rejects future dates before unsigned subtraction" {
    for ([_]aida.Fecha{ date(2027, 1, 1), date(2026, 11, 1), date(2026, 10, 29) }) |birth|
        try std.testing.expectError(error.FutureDate, birth.ageOn(today));
}

test "ageOn validates both dates and can run at comptime" {
    try std.testing.expectError(error.InvalidDate, date(2025, 2, 30).ageOn(today));
    try std.testing.expectError(error.InvalidDate, date(1996, 1, 1).ageOn(date(2026, 13, 1)));
    const age = comptime try date(2000, 2, 29).ageOn(date(2030, 3, 1));
    try expect(age == 30);
}

test "teorico needs a birth date and thirty completed years" {
    try std.testing.expectError(error.TeoricoRequiereFechaNacimiento, aida.validarDocente(docente(null), today));
    try std.testing.expectError(error.TeoricoRequiereTreintaAnios, aida.validarDocente(docente(date(1996, 10, 29)), today));
    try aida.validarDocente(docente(date(1996, 10, 28)), today);
    try aida.validarDocente(docente(date(1970, 1, 1)), today);
}

test "teorico rejects future births and malformed civil dates" {
    try std.testing.expectError(error.FutureDate, aida.validarDocente(docente(date(2027, 1, 1)), today));
    try std.testing.expectError(error.InvalidDate, aida.validarDocente(docente(date(1996, 2, 30)), today));
}

test "docente retains experience threshold and its precedence" {
    var row = docente(null);
    for ([_]?i64{ null, -1, 0, 4 }) |experience| {
        row.experiencia = experience;
        try std.testing.expectError(error.TeoricoRequiereCincoAniosExperiencia, aida.validarDocente(row, today));
    }
    row.fecha_nacimiento = date(1996, 10, 28);
    for ([_]i64{ 5, 6 }) |experience| {
        row.experiencia = experience;
        try aida.validarDocente(row, today);
    }
}

test "docente age rule retains cargo normalization and ignores unrelated fields" {
    var row = docente(date(1996, 10, 29));
    row.cargo = " \tTEORICO\r\n";
    try std.testing.expectError(error.TeoricoRequiereTreintaAnios, aida.validarDocente(row, today));
    row.nombres = "Grace";
    row.telefono = "555-0100";
    row.esImportador = true;
    try std.testing.expectError(error.TeoricoRequiereTreintaAnios, aida.validarDocente(row, today));
    row.fecha_nacimiento = null;
    row.experiencia = null;
    for ([_]?[]const u8{ null, "", "practico" }) |cargo| {
        row.cargo = cargo;
        try aida.validarDocente(row, today);
    }
}
