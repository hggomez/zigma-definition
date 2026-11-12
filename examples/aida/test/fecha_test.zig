//! Calendario civil y conversiones puras del dominio, también evaluables en comptime.
const std = @import("std");
const Fecha = @import("aida").Fecha;

fn date(year: u16, month: u8, day: u8) Fecha {
    return .{ .@"año" = year, .mes = month, .@"día" = day };
}

test "Fecha valida los límites inclusivos del año y rechaza componentes inválidos" {
    try date(1, 1, 1).validate();
    try date(9999, 12, 31).validate();
    for ([_]Fecha{
        date(0, 1, 1),    date(10000, 1, 1), date(65535, 1, 1),
        date(2024, 0, 1), date(2024, 13, 1), date(2024, 255, 1),
        date(2024, 1, 0), date(2024, 1, 32), date(2024, 1, 255),
    }) |invalid| {
        try std.testing.expectError(error.InvalidDate, invalid.validate());
        try std.testing.expectError(error.InvalidDate, invalid.toIso());
    }
}

test "Fecha aplica los años bisiestos gregorianos y las excepciones de siglo" {
    for ([_]u16{ 4, 400, 1600, 2000, 2024 }) |year| try date(year, 2, 29).validate();
    for ([_]u16{ 1, 100, 1500, 1900, 2025, 2100, 9999 }) |year| {
        try date(year, 2, 28).validate();
        try std.testing.expectError(error.InvalidDate, date(year, 2, 29).validate());
    }
    try std.testing.expectError(error.InvalidDate, date(2024, 2, 30).validate());
}

test "Fecha comprueba el último día de cada mes" {
    const last_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    for (last_days, 1..) |last_day, month| {
        try date(2025, @intCast(month), last_day).validate();
        try std.testing.expectError(error.InvalidDate, date(2025, @intCast(month), last_day + 1).validate());
    }
}

test "Fecha ISO acepta exactamente diez bytes ASCII y fechas reales del calendario" {
    for ([_][]const u8{
        "",            "2024-2-29",   "2024-02-9",    "024-02-29",            "10000-01-01",
        "+024-02-29",  "2024-+2-29",  "2024-02-+9",   "2024-02--1",           "2024/02/29",
        "2024-02_29",  "2_24-02-29",
        "２０２４-02-29",
        " 2024-02-29", "2024-02-29 ", "2024-02-29\n", "2024-02-29T00:00:00Z", "0000-01-01",
        "1900-02-29",  "2100-02-29",  "2025-02-30",   "2024-04-31",           "2024-00-01",
        "2024-13-01",  "2024-01-00",  "2024-01-32",
    }) |bytes| try std.testing.expectError(error.InvalidDate, Fecha.fromIso(bytes));
}

test "La conversión de ida y vuelta ISO conserva los ceros iniciales y los componentes" {
    const values = [_]Fecha{ date(1, 1, 1), date(42, 3, 9), date(2000, 2, 29), date(2024, 12, 31), date(9999, 12, 31) };
    const strings = [_][]const u8{ "0001-01-01", "0042-03-09", "2000-02-29", "2024-12-31", "9999-12-31" };
    for (values, strings) |value, bytes| {
        const encoded = try value.toIso();
        try std.testing.expect(@TypeOf(encoded) == [10]u8);
        try std.testing.expectEqualStrings(bytes, &encoded);
        try std.testing.expect(std.meta.eql(value, try Fecha.fromIso(bytes)));
    }
}

test "Las operaciones de Fecha funcionan en compilación sin validar implícitamente los literales" {
    const leap = comptime try Fecha.fromIso("2000-02-29");
    comptime try leap.validate();
    const iso = comptime try leap.toIso();
    try std.testing.expectEqualStrings("2000-02-29", &iso);
    const invalid = date(2025, 2, 30);
    try std.testing.expect(invalid.@"día" == 30);
    try std.testing.expectError(error.InvalidDate, invalid.validate());
}
