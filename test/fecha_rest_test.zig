//! Validación civil antes del repositorio y errores internos sanitizados.
const std = @import("std");
const zigma = @import("zigma");
const rest = @import("zigma_rest");
const aida = @import("aida");
const aida_rest = @import("aida_rest");
const fixture = @import("fixtures/validation_repository.zig");
const FailOnceAllocator = @import("fixtures/fail_once_allocator.zig");
const allocator = std.testing.allocator;
const expect = std.testing.expect;
const expectText = std.testing.expectEqualStrings;

// Un contrato pequeño demuestra que la comprobación depende del codec de dominio,
// sin agregar una regla específica a clases ni a otra entidad de AIDA.
const definition = .{ .pk = .{"id"}, .fields = zigma.record(aida.type_defs, .{
    .id = .{ .type = "integer" },
    .date = .{ .type = "fecha" },
    .note = .{ .type = "text" },
}) };
const Event = zigma.Entity(aida.type_defs, definition);
const Model = zigma.Framework(aida.type_defs, .{ .events = .{ .Type = Event, .definition = definition } });
const Repository = fixture.Repository(&.{ "id", "date", "note" });
const cells = &.{ "1", "2024-02-29", "original" };
const Api = rest.Api(Model, aida_rest.codecs, .{});
const Observer = struct {
    var calls: usize = 0;
    fn validate(_: Event, _: void) ?rest.BusinessRuleViolation {
        calls += 1;
        return null;
    }
};
const validators = rest.defineBusinessValidators(Model, .{ .events = rest.BusinessValidator(Event, void){ .validate = Observer.validate } });
const ValidatedApi = rest.Api(Model, aida_rest.codecs, validators);

fn request(method: rest.Method, target: []const u8, body: []const u8) rest.Request {
    return .{ .method = method, .target = target, .content_type = "application/json", .body = body };
}

fn expectNoCalls(repository: Repository) !void {
    try expect(repository.select_calls == 0 and repository.insert_calls == 0 and
        repository.update_calls == 0 and repository.delete_calls == 0 and repository.deinit_calls == 0);
}

fn expectInvalidRequest(response: rest.Response) !void {
    try expect(response.status == 400);
    try expectText("{\"error\":{\"code\":\"invalid_request\",\"message\":\"Request fields or values are invalid\"}}", response.body);
}

test "Fecha POST rejects impossible objects before repository calls with or without a validator" {
    inline for (.{ Api, ValidatedApi }) |ApiType| {
        for ([_][]const u8{
            "{\"id\":1,\"date\":{\"año\":2025,\"mes\":2,\"día\":30}}",
            "{\"id\":1,\"date\":{\"año\":0,\"mes\":1,\"día\":1}}",
            "{\"id\":1,\"date\":{\"año\":10000,\"mes\":1,\"día\":1}}",
            "{\"id\":1,\"date\":\"2024-02-29\"}",
        }) |body| {
            Observer.calls = 0;
            var repository = Repository{};
            var api = ApiType.init(.{});
            const response = try api.handle(allocator, &repository, request(.POST, "/api/events", body), {});
            defer allocator.free(response.body);
            try expectInvalidRequest(response);
            try expectNoCalls(repository);
            try expect(Observer.calls == 0);
        }
    }
}

test "Fecha PUT rejects impossible objects before selecting rows for business validation" {
    inline for (.{ Api, ValidatedApi }) |ApiType| {
        Observer.calls = 0;
        var repository = Repository{ .rows = &.{cells} };
        var api = ApiType.init(.{});
        const response = try api.handle(allocator, &repository, request(.PUT, "/api/events?id=1", "{\"date\":{\"año\":2100,\"mes\":2,\"día\":29}}"), {});
        defer allocator.free(response.body);
        try expectInvalidRequest(response);
        try expectNoCalls(repository);
        try expect(Observer.calls == 0);
    }
}

test "Fecha invalid filters reject GET PUT and DELETE before any repository call" {
    for ([_][]const u8{
        "/api/events?date=2025-02-30",
        "/api/events?date=%7B%22a%C3%B1o%22%3A1900%2C%22mes%22%3A2%2C%22d%C3%ADa%22%3A29%7D",
    }) |target| {
        for ([_]rest.Method{ .GET, .PUT, .DELETE }) |method| {
            var repository = Repository{ .rows = &.{cells} };
            var api = Api.init(.{});
            const response = try api.handle(allocator, &repository, request(method, target, "{\"note\":\"changed\"}"), {});
            defer allocator.free(response.body);
            try expectInvalidRequest(response);
            try expectNoCalls(repository);
        }
    }
}

test "Fecha valid objects retain JSON representation and ISO repository parameters" {
    var repository = Repository{ .expected_parameters = &.{
        .{ .name = "id", .value = "1" },
        .{ .name = "date", .value = "2000-02-29" },
        .{ .name = "note", .value = null },
    } };
    var api = Api.init(.{});
    const response = try api.handle(allocator, &repository, request(.POST, "/api/events", "{\"id\":1,\"date\":{\"año\":2000,\"mes\":2,\"día\":29}}"), {});
    defer allocator.free(response.body);
    try expect(response.status == 201 and repository.parameters_match and repository.deinit_calls == 1);
    try expectText("{\"id\":1,\"date\":{\"año\":2000,\"mes\":2,\"día\":29},\"note\":null}", response.body);
}

test "Fecha nullable POST PUT and stored results bypass date codecs" {
    // Estos codecs fallarían si recibieran null; REST debe resolverlo por sí mismo.
    const NullApi = rest.Api(Model, oom_codecs, .{});
    for ([_][]const u8{ "{\"id\":1}", "{\"id\":1,\"date\":null}" }) |body| {
        var repository = Repository{};
        var api = NullApi.init(.{});
        const response = try api.handle(allocator, &repository, request(.POST, "/api/events", body), {});
        defer allocator.free(response.body);
        try expect(response.status == 201);
        try expectText("{\"id\":1,\"date\":null,\"note\":null}", response.body);
    }
    var repository = Repository{ .rows = &.{&.{ "1", null, "original" }}, .expected_parameters = &.{.{ .name = "date", .value = null }} };
    var api = NullApi.init(.{});
    const response = try api.handle(allocator, &repository, request(.PUT, "/api/events?id=1", "{\"date\":null}"), {});
    defer allocator.free(response.body);
    try expect(response.status == 200 and repository.parameters_match);
    try expectText("[{\"id\":1,\"date\":null,\"note\":\"original\"}]", response.body);
}

test "Fecha invalid stored values produce sanitized response errors and release results" {
    for ([_][]const u8{ "2025-02-30", "0000-01-01", "10000-01-01", "secret-invalid-date" }) |date| {
        var repository = Repository{ .rows = &.{&.{ "1", date, "original" }} };
        var api = Api.init(.{});
        const response = try api.handle(allocator, &repository, request(.GET, "/api/events", ""), {});
        defer allocator.free(response.body);
        try expect(response.status == 500);
        try expectText("{\"error\":{\"code\":\"invalid_repository_result\",\"message\":\"Repository returned an invalid row shape\"}}", response.body);
        try expect(repository.select_calls == 1 and repository.deinit_calls == 1);
    }
}

test "Fecha invalid stored values keep business conversion error and prevent PUT writes" {
    for ([_][]const u8{ "2025-02-30", "0000-01-01", "10000-01-01", "secret-invalid-date" }) |date| {
        Observer.calls = 0;
        var repository = Repository{ .rows = &.{&.{ "1", date, "original" }} };
        var api = ValidatedApi.init(.{});
        const response = try api.handle(allocator, &repository, request(.PUT, "/api/events?id=1", "{\"note\":\"changed\"}"), {});
        defer allocator.free(response.body);
        try expect(response.status == 500);
        try expectText("{\"error\":{\"code\":\"business_validation_error\",\"message\":\"Business validation could not be completed\"}}", response.body);
        try expect(repository.select_calls == 1 and repository.update_calls == 0 and repository.deinit_calls == 1);
        try expect(Observer.calls == 0);
    }
}

fn textOom(_: std.mem.Allocator, _: []const u8) rest.CodecError![]const u8 {
    return error.OutOfMemory;
}
fn jsonOom(_: std.mem.Allocator, _: std.json.Value) rest.CodecError![]const u8 {
    return error.OutOfMemory;
}
fn resultOom(_: std.mem.Allocator, _: []const u8) rest.CodecError!std.json.Value {
    return error.OutOfMemory;
}
const oom_codecs = zigma.merge(.{ aida_rest.codecs, .{ .fecha = rest.Codec{
    .queryToPostgres = textOom,
    .jsonToPostgres = jsonOom,
    .postgresToJson = resultOom,
} } });

fn expectMemoryError(result: anyerror!rest.Response, backing: std.mem.Allocator) !void {
    if (result) |response| {
        defer backing.free(response.body);
        std.debug.print("Expected OutOfMemory, received HTTP {d}: {s}\n", .{ response.status, response.body });
        return error.TestUnexpectedResult;
    } else |err| try expect(err == error.OutOfMemory);
}

test "Fecha input codec OutOfMemory propagates through POST and PUT without repository calls" {
    for ([_]rest.Method{ .POST, .PUT }) |method| {
        var repository = Repository{};
        var api = rest.Api(Model, oom_codecs, .{}).init(.{});
        const body = if (method == .POST) "{\"id\":1,\"date\":{\"año\":2024,\"mes\":2,\"día\":29}}" else "{\"date\":{\"año\":2024,\"mes\":2,\"día\":29}}";
        const target = if (method == .PUT) "/api/events?id=1" else "/api/events";
        try expectMemoryError(api.handle(allocator, &repository, request(method, target, body), {}), allocator);
        try expectNoCalls(repository);
    }
}

test "Fecha query codec OutOfMemory propagates without repository calls" {
    var repository = Repository{};
    var api = rest.Api(Model, oom_codecs, .{}).init(.{});
    try expectMemoryError(api.handle(allocator, &repository, request(.GET, "/api/events?date=2024-02-29", ""), {}), allocator);
    try expectNoCalls(repository);
}

test "Fecha result codec OutOfMemory propagates and releases the repository result" {
    var repository = Repository{ .rows = &.{cells} };
    var api = rest.Api(Model, oom_codecs, .{}).init(.{});
    try expectMemoryError(api.handle(allocator, &repository, request(.GET, "/api/events", ""), {}), allocator);
    try expect(repository.deinit_calls == 1);
}

test "Fecha business conversion OutOfMemory propagates without updating" {
    var repository = Repository{ .rows = &.{cells} };
    var api = rest.Api(Model, oom_codecs, validators).init(.{});
    try expectMemoryError(api.handle(allocator, &repository, request(.PUT, "/api/events?id=1", "{\"note\":\"changed\"}"), {}), allocator);
    try expect(repository.update_calls == 0 and repository.deinit_calls == 1);
}

test "REST parsing OutOfMemory is not hidden by a successful error response allocation" {
    // Sin filtros, la primera reserva pertenece al parsing del cuerpo. Después de
    // ese fallo el allocator vuelve a funcionar: un 400 incorrecto queda observable.
    var failing = FailOnceAllocator{ .backing = allocator, .fail_index = 0 };
    const backing = failing.allocator();
    var repository = Repository{};
    var api = Api.init(.{});
    try expectMemoryError(api.handle(backing, &repository, request(.POST, "/api/events", "{\"id\":1,\"date\":{\"año\":2024,\"mes\":2,\"día\":29}}"), {}), backing);
    try expect(failing.failed);
    try expectNoCalls(repository);
}

fn allocationScenario(backing: std.mem.Allocator, req: rest.Request) !void {
    var repository = Repository{ .rows = &.{cells} };
    var api = Api.init(.{});
    const response = try api.handle(backing, &repository, req, {});
    defer backing.free(response.body);
    try expect(response.status == if (req.method == .POST) @as(u16, 201) else 200);
}

test "REST Fecha requests clean up and propagate all allocation failures" {
    for ([_]rest.Request{
        request(.POST, "/api/events", "{\"id\":1,\"date\":{\"año\":2024,\"mes\":2,\"día\":29}}"),
        request(.PUT, "/api/events?id=1", "{\"date\":{\"año\":2024,\"mes\":2,\"día\":29}}"),
        request(.GET, "/api/events?date=2024-02-29", ""),
    }) |req| try std.testing.checkAllAllocationFailures(allocator, allocationScenario, .{req});
}
