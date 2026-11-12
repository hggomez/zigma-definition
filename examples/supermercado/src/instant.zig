//! Calendario compartido por selección histórica y codecs; no consulta el reloj.
const std = @import("std");

pub const Instant = struct {
    year: u16,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    millisecond: u16 = 0,

    pub fn format(self: Instant, allocator: std.mem.Allocator) error{OutOfMemory}![]const u8 {
        return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            self.year, self.month, self.day, self.hour, self.minute, self.second, self.millisecond,
        });
    }

    fn shiftToUtc(self: *Instant, offset_seconds: i32) error{InvalidValue}!void {
        const seconds = @as(i32, self.hour) * 3600 + @as(i32, self.minute) * 60 + self.second - offset_seconds;
        const day_shift = @divFloor(seconds, 86400);
        const within_day = @mod(seconds, 86400);
        self.hour = @intCast(@divTrunc(within_day, 3600));
        self.minute = @intCast(@divTrunc(@mod(within_day, 3600), 60));
        self.second = @intCast(@mod(within_day, 60));
        if (day_shift < 0) {
            if (self.day > 1) {
                self.day -= 1;
            } else {
                if (self.month == 1) {
                    if (self.year == 1) return error.InvalidValue;
                    self.year -= 1;
                    self.month = 12;
                } else self.month -= 1;
                self.day = daysInMonth(self.year, self.month);
            }
        } else if (day_shift > 0) {
            if (self.day < daysInMonth(self.year, self.month)) {
                self.day += 1;
            } else {
                if (self.month == 12) {
                    if (self.year == 9999) return error.InvalidValue;
                    self.year += 1;
                    self.month = 1;
                } else self.month += 1;
                self.day = 1;
            }
        }
    }
};

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        2 => if (year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

fn digits(comptime T: type, text: []const u8) error{InvalidValue}!T {
    for (text) |byte| if (!std.ascii.isDigit(byte)) return error.InvalidValue;
    return std.fmt.parseInt(T, text, 10) catch error.InvalidValue;
}

fn parseDateTime(text: []const u8) error{InvalidValue}!Instant {
    if (text.len < 19 or text[4] != '-' or text[7] != '-' or
        (text[10] != 'T' and text[10] != ' ') or text[13] != ':' or text[16] != ':') return error.InvalidValue;
    const value: Instant = .{
        .year = try digits(u16, text[0..4]),
        .month = try digits(u8, text[5..7]),
        .day = try digits(u8, text[8..10]),
        .hour = try digits(u8, text[11..13]),
        .minute = try digits(u8, text[14..16]),
        .second = try digits(u8, text[17..19]),
    };
    if (value.year == 0 or value.month < 1 or value.month > 12 or value.day < 1 or
        value.day > daysInMonth(value.year, value.month) or value.hour > 23 or value.minute > 59 or value.second > 59)
        return error.InvalidValue;
    return value;
}

/// Formato público único: permite comparar instantes válidos lexicográficamente.
pub fn parseCanonical(text: []const u8) error{InvalidValue}!Instant {
    if (text.len != 24 or text[10] != 'T' or text[19] != '.' or text[23] != 'Z') return error.InvalidValue;
    var value = try parseDateTime(text);
    value.millisecond = try digits(u16, text[20..23]);
    return value;
}

/// DateStyle ISO de PostgreSQL: zona obligatoria, hasta seis decimales, sin pérdida de precisión.
pub fn parsePostgres(text: []const u8) error{InvalidValue}!Instant {
    var value = try parseDateTime(text);
    var position: usize = 19;
    if (position < text.len and text[position] == '.') {
        position += 1;
        const start = position;
        while (position < text.len and std.ascii.isDigit(text[position])) : (position += 1) {}
        const count = position - start;
        if (count == 0 or count > 6) return error.InvalidValue;
        for (text[start..position], 0..) |byte, index| {
            if (index < 3) {
                value.millisecond = value.millisecond * 10 + byte - '0';
            } else if (byte != '0') return error.InvalidValue;
        }
        if (count == 1) value.millisecond *= 100;
        if (count == 2) value.millisecond *= 10;
    }
    const zone = text[position..];
    if (std.mem.eql(u8, zone, "Z")) return value;
    if ((zone.len != 3 and zone.len != 6 and zone.len != 9) or
        (zone[0] != '+' and zone[0] != '-')) return error.InvalidValue;
    const hours = try digits(i32, zone[1..3]);
    var minutes: i32 = 0;
    var seconds: i32 = 0;
    if (zone.len >= 6) {
        if (zone[3] != ':') return error.InvalidValue;
        minutes = try digits(i32, zone[4..6]);
    }
    if (zone.len == 9) {
        if (zone[6] != ':') return error.InvalidValue;
        seconds = try digits(i32, zone[7..9]);
    }
    if (hours > 15 or minutes > 59 or seconds > 59) return error.InvalidValue;
    const offset = hours * 3600 + minutes * 60 + seconds;
    try value.shiftToUtc(if (zone[0] == '-') -offset else offset);
    return value;
}
