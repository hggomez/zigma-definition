//! AIDA REST codecs and the controller type generated from the same entities.

const std = @import("std");
const zigma = @import("zigma");
const rest = @import("zigma_rest");
const aida = @import("aida");

fn validIsoDate(value: []const u8) bool {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return false;
    for (value, 0..) |byte, index| {
        if (index == 4 or index == 7) continue;
        if (!std.ascii.isDigit(byte)) return false;
    }
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return false;
    if (month == 0 or month > 12 or day == 0) return false;
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    const month_days = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return day <= month_days[month - 1];
}

fn dateFromQuery(allocator: std.mem.Allocator, value: []const u8) rest.CodecError![]const u8 {
    if (!validIsoDate(value)) return error.InvalidValue;
    return allocator.dupe(u8, value) catch error.OutOfMemory;
}

fn dateFromJson(allocator: std.mem.Allocator, value: std.json.Value) rest.CodecError![]const u8 {
    if (value != .string or !validIsoDate(value.string)) return error.InvalidValue;
    return allocator.dupe(u8, value.string) catch error.OutOfMemory;
}

fn dateToJson(_: std.mem.Allocator, value: []const u8) rest.CodecError!std.json.Value {
    if (!validIsoDate(value)) return error.InvalidValue;
    return .{ .string = value };
}

pub const date_codec = rest.Codec{
    .queryToPostgres = dateFromQuery,
    .jsonToPostgres = dateFromJson,
    .postgresToJson = dateToJson,
};

pub const codecs = rest.defineCodecs(aida.type_defs, zigma.merge(.{
    rest.common_codecs,
    .{
        .fecha = date_codec,
        .email = rest.text_codec,
    },
}));

pub const Api = rest.Api(aida.entity_defs, codecs);
