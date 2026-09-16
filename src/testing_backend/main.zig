//! Backend de pruebas en memoria para desarrollar el frontend sin PostgreSQL.
//! Compone la API REST del sistema, sus seeds y el transporte HTTP compartido.
//! Los datos se descartan al terminar el proceso.

const std = @import("std");
const zigma = @import("zigma");
const rest = @import("zigma_rest");
const std_http = @import("zigma_std_http");
const system = @import("system");
const app_rest = @import("app_rest");
const MemoryRepository = @import("memory_repository").MemoryRepository;

const Model = zigma.System(system.type_defs, system.entity_defs);
const Repo = MemoryRepository(Model);
const entity_names = @typeInfo(@TypeOf(Model.info)).@"struct".field_names;

pub fn main(init: std.process.Init) !void {
    var repository = try Repo.init(init.gpa);
    defer repository.deinit();
    try seed(init.gpa, &repository);

    var api = app_rest.Api.init(.{});
    const address = init.environ_map.get("HTTP_ADDRESS") orelse "127.0.0.1";
    const port = if (init.environ_map.get("HTTP_PORT")) |value|
        try std.fmt.parseInt(u16, value, 10)
    else
        8080;

    std.debug.print("Testing backend (in memory) listening on http://{s}:{d}/api\n", .{ address, port });
    try std_http.serve(init.io, init.gpa, &api, &repository, .{
        .address = address,
        .port = port,
    });
}

fn seed(gpa: std.mem.Allocator, repository: *Repo) !void {
    if (!@hasDecl(system, "seeds")) return;
    inline for (entity_names) |entity_name| {
        if (!@hasField(@TypeOf(system.seeds), entity_name)) continue;
        const entity = @field(Model.info, entity_name);
        for (@field(system.seeds, entity_name)) |row| {
            var values_buf: [64]rest.FieldValue = undefined;
            const values = try rowToFieldValues(gpa, entity, row, &values_buf);
            defer freeFieldValues(gpa, values);
            var result = try repository.insert(gpa, entity_name, values);
            result.deinit();
        }
    }
}

fn rowToFieldValues(
    allocator: std.mem.Allocator,
    comptime entity: anytype,
    row: anytype,
    buf: []rest.FieldValue,
) ![]rest.FieldValue {
    const field_names = @typeInfo(@TypeOf(entity.fields)).@"struct".field_names;
    if (field_names.len > buf.len) return error.OutOfMemory;
    inline for (field_names, 0..) |field_name, i| {
        buf[i] = .{
            .name = field_name,
            .value = try zigValueToText(allocator, @field(row, field_name)),
        };
    }
    return buf[0..field_names.len];
}

fn freeFieldValues(allocator: std.mem.Allocator, values: []rest.FieldValue) void {
    for (values) |value| if (value.value) |bytes| allocator.free(bytes);
}

fn zigValueToText(allocator: std.mem.Allocator, value: anytype) !?[]u8 {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => {
            if (value) |inner| return zigValueToText(allocator, inner);
            return null;
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return try allocator.dupe(u8, value);
            @compileError("unsupported seed field type " ++ @typeName(T));
        },
        .int => return try std.fmt.allocPrint(allocator, "{d}", .{value}),
        .bool => return try allocator.dupe(u8, if (value) "true" else "false"),
        .@"struct" => {
            if (@hasField(T, "año") and @hasField(T, "mes") and @hasField(T, "día")) {
                return try std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{
                    value.@"año",
                    value.mes,
                    value.@"día",
                });
            }
            @compileError("unsupported seed struct " ++ @typeName(T));
        },
        else => @compileError("unsupported seed field type " ++ @typeName(T)),
    }
}
