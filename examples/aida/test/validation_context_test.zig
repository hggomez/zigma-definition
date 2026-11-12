//! Día civil de AIDA a partir del reloj UTC de la solicitud.
const std = @import("std");
const aida = @import("aida");
const aida_rest = @import("aida_rest");

test "El contexto de AIDA convierte instantes UTC en el límite del día civil argentino" {
    // 2026-10-28 02:59:59 y 03:00:00 UTC: medianoche en UTC-03:00.
    const before = try aida_rest.contextFromTimestamp(1793156399);
    const after = try aida_rest.contextFromTimestamp(1793156400);
    try std.testing.expect(std.meta.eql(before.today, aida.Fecha{ .@"año" = 2026, .mes = 10, .@"día" = 27 }));
    try std.testing.expect(std.meta.eql(after.today, aida.Fecha{ .@"año" = 2026, .mes = 10, .@"día" = 28 }));
}

test "La conversión del contexto de AIDA respeta los cambios de año y los días bisiestos" {
    const cases = [_]struct { seconds: i64, expected: aida.Fecha }{
        .{ .seconds = 1798772400, .expected = .{ .@"año" = 2027, .mes = 1, .@"día" = 1 } },
        .{ .seconds = 1709175600, .expected = .{ .@"año" = 2024, .mes = 2, .@"día" = 29 } },
        .{ .seconds = 1709262000, .expected = .{ .@"año" = 2024, .mes = 3, .@"día" = 1 } },
        .{ .seconds = -62135586000, .expected = .{ .@"año" = 1, .mes = 1, .@"día" = 1 } },
        .{ .seconds = -2208978000, .expected = .{ .@"año" = 1900, .mes = 1, .@"día" = 1 } },
        .{ .seconds = 253402311599, .expected = .{ .@"año" = 9999, .mes = 12, .@"día" = 31 } },
    };
    for (cases) |case| {
        const context = try aida_rest.contextFromTimestamp(case.seconds);
        try std.testing.expect(std.meta.eql(context.today, case.expected));
    }
}

test "El contexto de AIDA rechaza instantes fuera del rango de Fecha sin desbordarse" {
    try std.testing.expectError(error.InvalidDate, aida_rest.contextFromTimestamp(-62135586001));
    try std.testing.expectError(error.InvalidDate, aida_rest.contextFromTimestamp(253402311600));
    try std.testing.expectError(error.InvalidDate, aida_rest.contextFromTimestamp(std.math.minInt(i64)));
    try std.testing.expectError(error.InvalidDate, aida_rest.contextFromTimestamp(std.math.maxInt(i64)));
}
