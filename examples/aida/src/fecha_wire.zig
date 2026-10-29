//! Adaptación de Fecha entre objetos JSON y texto PostgreSQL DATE.
//! El dominio concentra la validación civil y el formato ISO; REST resuelve null.

const std = @import("std");
const rest = @import("zigma_rest");
const aida = @import("aida");

fn dateToPostgres(allocator: std.mem.Allocator, fecha: aida.Fecha) rest.CodecError![]const u8 {
    const iso = fecha.toIso() catch return error.InvalidValue;
    return allocator.dupe(u8, &iso);
}

fn dateFromQuery(allocator: std.mem.Allocator, value: []const u8) rest.CodecError![]const u8 {
    if (aida.Fecha.fromIso(value)) |fecha| {
        return dateToPostgres(allocator, fecha);
    } else |_| {}
    const fecha = std.json.parseFromSliceLeaky(aida.Fecha, allocator, value, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidValue,
    };
    return dateToPostgres(allocator, fecha);
}

fn dateFromJson(allocator: std.mem.Allocator, value: std.json.Value) rest.CodecError![]const u8 {
    const fecha = std.json.parseFromValueLeaky(aida.Fecha, allocator, value, .{}) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidValue,
    };
    return dateToPostgres(allocator, fecha);
}

fn dateToJson(allocator: std.mem.Allocator, value: []const u8) rest.CodecError!std.json.Value {
    const fecha = aida.Fecha.fromIso(value) catch return error.InvalidValue;
    var object: std.json.ObjectMap = .empty;
    errdefer object.deinit(allocator);
    try object.put(allocator, "año", .{ .integer = fecha.@"año" });
    try object.put(allocator, "mes", .{ .integer = fecha.mes });
    try object.put(allocator, "día", .{ .integer = fecha.@"día" });
    return .{ .object = object };
}

pub const codec = rest.Codec{
    .queryToPostgres = dateFromQuery,
    .jsonToPostgres = dateFromJson,
    .postgresToJson = dateToJson,
};
