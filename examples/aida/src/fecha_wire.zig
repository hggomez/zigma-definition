//! Wire encoding for AIDA `Fecha`: JSON domain object ↔ PostgreSQL DATE text.
//! No calendar validation — only the struct shape from `aida.Fecha`.

const std = @import("std");
const rest = @import("zigma_rest");
const aida = @import("aida");

fn isoFromFecha(allocator: std.mem.Allocator, fecha: aida.Fecha) rest.CodecError![]const u8 {
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        fecha.@"año",
        fecha.mes,
        fecha.@"día",
    }) catch error.OutOfMemory;
}

fn fechaFromIso(value: []const u8) rest.CodecError!aida.Fecha {
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return error.InvalidValue;
    return .{
        .@"año" = std.fmt.parseInt(u16, value[0..4], 10) catch return error.InvalidValue,
        .mes = std.fmt.parseInt(u8, value[5..7], 10) catch return error.InvalidValue,
        .@"día" = std.fmt.parseInt(u8, value[8..10], 10) catch return error.InvalidValue,
    };
}

fn dateFromQuery(allocator: std.mem.Allocator, value: []const u8) rest.CodecError![]const u8 {
    if (fechaFromIso(value)) |fecha| {
        return isoFromFecha(allocator, fecha);
    } else |_| {}
    const fecha = std.json.parseFromSliceLeaky(aida.Fecha, allocator, value, .{}) catch return error.InvalidValue;
    return isoFromFecha(allocator, fecha);
}

fn dateFromJson(allocator: std.mem.Allocator, value: std.json.Value) rest.CodecError![]const u8 {
    const fecha = std.json.parseFromValueLeaky(aida.Fecha, allocator, value, .{}) catch return error.InvalidValue;
    return isoFromFecha(allocator, fecha);
}

fn dateToJson(allocator: std.mem.Allocator, value: []const u8) rest.CodecError!std.json.Value {
    const fecha = try fechaFromIso(value);
    const object_json = std.fmt.allocPrint(allocator, "{{\"año\":{d},\"mes\":{d},\"día\":{d}}}", .{
        fecha.@"año",
        fecha.mes,
        fecha.@"día",
    }) catch return error.OutOfMemory;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, object_json, .{}) catch return error.InvalidValue;
    return parsed.value;
}

pub const codec = rest.Codec{
    .queryToPostgres = dateFromQuery,
    .jsonToPostgres = dateFromJson,
    .postgresToJson = dateToJson,
};
