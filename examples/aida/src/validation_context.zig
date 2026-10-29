//! La aplicación elige el día civil; el contrato y las reglas no leen el reloj.
const std = @import("std");
const aida = @import("aida");

pub const ValidationContext = struct { today: aida.Fecha };

/// Política de AIDA: UTC−03:00 fijo, independiente de la zona del sistema operativo.
pub fn contextFromTimestamp(seconds: i64) error{InvalidDate}!ValidationContext {
    const epoch = std.time.epoch;
    // i128 evita desbordar al ajustar incluso los extremos del timestamp recibido.
    const days = @divFloor(@as(i128, seconds) - 3 * 60 * 60, epoch.secs_per_day);
    // Días respecto de 1970 para 0001-01-01 y 9999-12-31, respectivamente.
    if (days < -719162 or days > 2932896) return error.InvalidDate;
    var remaining: i32 = @intCast(days);
    var year: u16 = epoch.epoch_year;
    while (remaining < 0) {
        year -= 1;
        remaining += epoch.getDaysInYear(year);
    }
    while (remaining >= epoch.getDaysInYear(year)) {
        remaining -= epoch.getDaysInYear(year);
        year += 1;
    }
    const year_day: epoch.YearAndDay = .{ .year = year, .day = @intCast(remaining) };
    const month_day = year_day.calculateMonthDay();
    const today: aida.Fecha = .{ .@"año" = year, .mes = month_day.month.numeric(), .@"día" = @as(u8, month_day.day_index) + 1 };
    try today.validate();
    return .{ .today = today };
}

pub const ContextProvider = struct {
    io: std.Io,

    pub fn get(self: *const ContextProvider) error{InvalidDate}!ValidationContext {
        return contextFromTimestamp(std.Io.Clock.real.now(self.io).toSeconds());
    }
};
