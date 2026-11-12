//! Contrato HTTP del CRUD; las operaciones transaccionales de caja pertenecen a otra etapa.
const std = @import("std");
const rest = @import("zigma_rest");
const contract = @import("supermercado");
const application = @import("application_rest");
const fixture = @import("fixtures/validation_repository.zig");
const allocator = std.testing.allocator;

fn Repository(comptime entity: []const u8) type {
    return fixture.Repository(@typeInfo(@TypeOf(@field(contract.Model.info, entity).fields)).@"struct".field_names);
}

fn request(method: rest.Method, target: []const u8, body: []const u8) rest.Request {
    return .{ .method = method, .target = target, .body = body, .content_type = "application/json" };
}

fn expectCode(response: rest.Response, status: u16, code: []const u8) !void {
    try std.testing.expect(response.status == status);
    const json = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer json.deinit();
    const violation = json.value.object.get("error").?.object;
    try std.testing.expectEqualStrings(code, violation.get("code").?.string);
    try std.testing.expect(violation.get("message").?.string.len > 0);
}

fn expectPostRejected(comptime entity: []const u8, body: []const u8, code: []const u8) !void {
    var repository = Repository(entity){};
    var api = application.Api.init(.{});
    const response = try api.handle(allocator, &repository, request(.POST, "/api/" ++ entity, body), {});
    defer allocator.free(response.body);
    try expectCode(response, 422, code);
    try std.testing.expect(repository.insert_calls == 0 and repository.select_calls == 0);
}

test "la API publica las ocho rutas CRUD con contexto void y codecs para todos los dominios" {
    try std.testing.expect(application.Api.ValidationContext == void);
    try std.testing.expect(application.Api.routes.len == 8);
    inline for (@typeInfo(@TypeOf(contract.Model.info)).@"struct".field_names, 0..) |name, i| {
        try std.testing.expectEqualStrings("/api/" ++ name, application.Api.routes[i].path);
    }
    inline for (@typeInfo(@TypeOf(contract.type_defs)).@"struct".field_names) |name| {
        try std.testing.expect(@TypeOf(@field(application.codecs, name)) == rest.Codec);
    }
}

test "el codec de importe conserva centavos enteros y rechaza fracciones y strings JSON" {
    const codec = application.codecs.importe;
    for ([_]i64{ 0, 199, std.math.maxInt(i64) }) |amount| {
        const sql = try codec.jsonToPostgres(allocator, .{ .integer = amount });
        defer allocator.free(sql);
        try std.testing.expect((try codec.postgresToJson(allocator, sql)).integer == amount);
    }
    try std.testing.expectError(error.InvalidValue, codec.jsonToPostgres(allocator, .{ .float = 1.25 }));
    try std.testing.expectError(error.InvalidValue, codec.jsonToPostgres(allocator, .{ .string = "199" }));
    try std.testing.expectError(error.InvalidValue, codec.queryToPostgres(allocator, "1.25"));
    try std.testing.expectError(error.InvalidValue, codec.queryToPostgres(allocator, "9223372036854775808"));
}

test "el codec de instante acepta UTC canónico con milisegundos y fechas reales" {
    for ([_][]const u8{ "0001-01-01T00:00:00.000Z", "2024-02-29T23:59:59.999Z", "9999-12-31T23:59:59.999Z" }) |value| {
        const query = try application.codecs.instante.queryToPostgres(allocator, value);
        defer allocator.free(query);
        const body = try application.codecs.instante.jsonToPostgres(allocator, .{ .string = value });
        defer allocator.free(body);
        try std.testing.expectEqualStrings(value, query);
        try std.testing.expectEqualStrings(value, body);
    }
}

test "las entradas de instante rechazan calendarios inválidos y formatos no canónicos" {
    for ([_][]const u8{
        "2025-02-29T00:00:00.000Z",      "1900-02-29T00:00:00.000Z", "0000-01-01T00:00:00.000Z",
        "2026-13-01T00:00:00.000Z",      "2026-04-31T00:00:00.000Z", "2026-01-01T24:00:00.000Z",
        "2026-01-01T00:00:60.000Z",      "2026-01-01T00:00:00Z",     "2026-01-01T00:00:00.000000Z",
        "2026-01-01T00:00:00.000-03:00", "2026-01-01 00:00:00.000Z", "infinity",
    }) |value| {
        try std.testing.expectError(error.InvalidValue, application.codecs.instante.queryToPostgres(allocator, value));
        try std.testing.expectError(error.InvalidValue, application.codecs.instante.jsonToPostgres(allocator, .{ .string = value }));
    }
    try std.testing.expectError(error.InvalidValue, application.codecs.instante.jsonToPostgres(allocator, .{ .integer = 1 }));
}

test "TIMESTAMPTZ se normaliza a UTC al cruzar husos horarios años y días bisiestos" {
    const cases = .{
        .{ "2026-11-12 12:34:56+00", "2026-11-12T12:34:56.000Z" },
        .{ "2026-11-12 12:34:56.1+00", "2026-11-12T12:34:56.100Z" },
        .{ "2026-11-12 12:34:56.12+00", "2026-11-12T12:34:56.120Z" },
        .{ "2026-11-12 12:34:56.123000+00", "2026-11-12T12:34:56.123Z" },
        .{ "2026-11-12 09:30:00-03", "2026-11-12T12:30:00.000Z" },
        .{ "2026-01-01 00:15:00+01:30", "2025-12-31T22:45:00.000Z" },
        .{ "2024-03-01 00:30:00+01", "2024-02-29T23:30:00.000Z" },
    };
    inline for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const json = try application.codecs.instante.postgresToJson(arena.allocator(), case[0]);
        try std.testing.expectEqualStrings(case[1], json.string);
    }
}

test "el codec rechaza instantes almacenados imposibles o con pérdida de precisión" {
    for ([_][]const u8{
        "infinity",               "-infinity",              "2025-02-29 00:00:00+00", "2026-01-01 00:00:00.123456+00",
        "0001-01-01 00:00:00+01", "9999-12-31 23:59:59-01", "2026-01-01 00:00:00",
    }) |value| {
        try std.testing.expectError(error.InvalidValue, application.codecs.instante.postgresToJson(allocator, value));
    }
}

test "POST permite filas válidas en las ocho entidades y conserva los opcionales como null" {
    inline for (.{
        .{ "productos", "{\"id\":1,\"nombre\":\"Yerba\",\"descripcion\":\"Paquete de 1 kg\"}" },
        .{ "productos_precios", "{\"id\":1,\"id_producto\":1,\"vigencia_desde\":\"2026-11-12T12:00:00.000Z\",\"precio\":199}" },
        .{ "clientes", "{\"id\":1,\"nombre\":\"Ana\"}" },
        .{ "carritos", "{\"id\":1,\"fecha_inicio\":\"2026-11-12T12:00:00.000Z\",\"estado\":\"abierto\"}" },
        .{ "productos_carritos", "{\"id_carrito\":1,\"id_producto\":1,\"cantidad\":3,\"id_precio\":1}" },
        .{ "descuentos_cantidad", "{\"id\":1,\"id_producto\":1,\"vigencia_desde\":\"2026-11-12T12:00:00.000Z\",\"cantidad_llevar\":3,\"descuento_porcentaje\":10,\"activo\":false}" },
        .{ "tickets", "{\"id\":1,\"id_carrito\":1,\"fecha_emision\":\"2026-11-12T12:00:00.000Z\",\"total\":0}" },
        .{ "tickets_productos", "{\"id_ticket\":1,\"id_producto\":1,\"cantidad\":3,\"precio_unitario\":199,\"importe_descuento\":0}" },
    }) |case| {
        var repository = Repository(case[0]){};
        var api = application.Api.init(.{});
        const response = try api.handle(allocator, &repository, request(.POST, "/api/" ++ case[0], case[1]), {});
        defer allocator.free(response.body);
        try std.testing.expect(response.status == 201 and repository.insert_calls == 1);
        const json = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
        defer json.deinit();
        inline for (@typeInfo(@TypeOf(@field(contract.Model.info, case[0]).fields)).@"struct".field_names) |name| {
            if (@field(@field(contract.Model.info, case[0]).fields, name).nullable)
                try std.testing.expect(json.value.object.get(name).? == .null);
        }
    }
}

test "POST rechaza precios no positivos sin escribir" {
    for ([_]i64{ 0, -1 }) |price| {
        const body = try std.fmt.allocPrint(allocator, "{{\"id\":1,\"id_producto\":1,\"vigencia_desde\":\"2026-11-12T12:00:00.000Z\",\"precio\":{d}}}", .{price});
        defer allocator.free(body);
        try expectPostRejected("productos_precios", body, "price_must_be_positive");
    }
}

test "las promociones exigen grupos positivos y porcentajes entre uno y cien incluso inactivas" {
    for ([_][2]i64{ .{ 0, 10 }, .{ -1, 10 }, .{ 3, 0 }, .{ 3, 101 } }) |case| {
        const body = try std.fmt.allocPrint(allocator, "{{\"id\":1,\"id_producto\":1,\"vigencia_desde\":\"2026-11-12T12:00:00.000Z\",\"cantidad_llevar\":{d},\"descuento_porcentaje\":{d},\"activo\":false}}", .{ case[0], case[1] });
        defer allocator.free(body);
        try expectPostRejected("descuentos_cantidad", body, "invalid_promotion");
    }
}

test "los renglones del carrito rechazan cantidades no positivas" {
    try expectPostRejected("productos_carritos", "{\"id_carrito\":1,\"id_producto\":1,\"cantidad\":0,\"id_precio\":1}", "quantity_must_be_positive");
    try expectPostRejected("productos_carritos", "{\"id_carrito\":1,\"id_producto\":1,\"cantidad\":-1,\"id_precio\":1}", "quantity_must_be_positive");
}

test "el CRUD acepta los tres estados declarados y rechaza estados desconocidos" {
    for ([_][]const u8{ "abierto", "cerrado", "cancelado" }) |state| {
        const body = try std.fmt.allocPrint(allocator, "{{\"id\":1,\"fecha_inicio\":\"2026-11-12T12:00:00.000Z\",\"estado\":\"{s}\"}}", .{state});
        defer allocator.free(body);
        var repository = Repository("carritos"){};
        var api = application.Api.init(.{});
        const response = try api.handle(allocator, &repository, request(.POST, "/api/carritos", body), {});
        defer allocator.free(response.body);
        try std.testing.expect(response.status == 201);
    }
    try expectPostRejected("carritos", "{\"id\":1,\"fecha_inicio\":\"2026-11-12T12:00:00.000Z\",\"estado\":\"desconocido\"}", "invalid_cart_state");
}

test "los tickets rechazan totales negativos y renglones con importes incoherentes o desbordados" {
    try expectPostRejected("tickets", "{\"id\":1,\"id_carrito\":1,\"fecha_emision\":\"2026-11-12T12:00:00.000Z\",\"total\":-1}", "invalid_ticket_total");
    for ([_][3]i64{ .{ 0, 100, 0 }, .{ 1, 0, 0 }, .{ 1, 100, -1 }, .{ 2, 100, 201 }, .{ 2, std.math.maxInt(i64), 0 } }) |case| {
        const body = try std.fmt.allocPrint(allocator, "{{\"id_ticket\":1,\"id_producto\":1,\"cantidad\":{d},\"precio_unitario\":{d},\"importe_descuento\":{d}}}", .{ case[0], case[1], case[2] });
        defer allocator.free(body);
        try expectPostRejected("tickets_productos", body, "invalid_ticket_line");
    }
}

test "PUT combina el patch con la fila almacenada y evita escribir si el descuento supera el bruto" {
    var repository = Repository("tickets_productos"){ .rows = &.{&.{ "1", "1", "3", "100", "250" }} };
    var api = application.Api.init(.{});
    const response = try api.handle(allocator, &repository, request(.PUT, "/api/tickets_productos?id_ticket=1&id_producto=1", "{\"cantidad\":2}"), {});
    defer allocator.free(response.body);
    try expectCode(response, 422, "invalid_ticket_line");
    try std.testing.expect(repository.select_calls == 1 and repository.update_calls == 0 and repository.deinit_calls == 1);
}

test "las fechas inválidas en el cuerpo o los filtros devuelven 400 sin consultar ni escribir" {
    var repository = Repository("productos_precios"){};
    var api = application.Api.init(.{});
    const post = try api.handle(allocator, &repository, request(.POST, "/api/productos_precios", "{\"id\":1,\"id_producto\":1,\"vigencia_desde\":\"2025-02-29T00:00:00.000Z\",\"precio\":100}"), {});
    defer allocator.free(post.body);
    const get = try api.handle(allocator, &repository, request(.GET, "/api/productos_precios?vigencia_desde=infinity", ""), {});
    defer allocator.free(get.body);
    try std.testing.expect(post.status == 400 and get.status == 400);
    try std.testing.expect(repository.select_calls == 0 and repository.insert_calls == 0);
}

test "GET devuelve centavos enteros e instantes UTC normalizados desde las filas PostgreSQL" {
    var repository = Repository("productos_precios"){ .rows = &.{&.{ "1", "1", "2026-11-12 09:30:00.12-03", "199" }} };
    var api = application.Api.init(.{});
    const response = try api.handle(allocator, &repository, request(.GET, "/api/productos_precios", ""), {});
    defer allocator.free(response.body);
    try std.testing.expect(response.status == 200 and repository.deinit_calls == 1);
    const json = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer json.deinit();
    const row = json.value.array.items[0].object;
    try std.testing.expect(row.get("precio").?.integer == 199);
    try std.testing.expectEqualStrings("2026-11-12T12:30:00.120Z", row.get("vigencia_desde").?.string);
}

fn convertInstantWithAllocationFailures(backing: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(backing);
    defer arena.deinit();
    _ = try application.codecs.instante.queryToPostgres(arena.allocator(), "2026-11-12T12:30:00.000Z");
    _ = try application.codecs.instante.jsonToPostgres(arena.allocator(), .{ .string = "2026-11-12T12:30:00.000Z" });
    _ = try application.codecs.instante.postgresToJson(arena.allocator(), "2026-11-12 09:30:00-03");
}

test "las conversiones de instante propagan los fallos de memoria y liberan resultados parciales" {
    try std.testing.checkAllAllocationFailures(allocator, convertInstantWithAllocationFailures, .{});
}
