//! Contrato de la validación REST con entidades concretas y repositorios textuales.
const std = @import("std");
const zigma = @import("zigma");
const rest = @import("zigma_rest");
const aida = @import("aida");
const aida_rest = @import("aida_rest");
const fixture = @import("fixtures/validation_repository.zig");
const expect = std.testing.expect;
const expectText = std.testing.expectEqualStrings;
const allocator = std.testing.allocator;

const domains = zigma.defineTypes(zigma.merge(.{ zigma.common_type_defs, .{
    .fecha = zigma.TypeDef{ .Type = aida.Fecha },
} }));
const definition = .{
    .pk = .{"id"},
    .fields = zigma.record(domains, .{
        .id = .{ .type = "integer" },
        .label = .{ .type = "text", .nullable = false },
        .enabled = .{ .type = "boolean", .nullable = false },
        .note = .{ .type = "text" },
        .count = .{ .type = "integer" },
        .approved = .{ .type = "boolean" },
        .date = .{ .type = "fecha" },
    }),
    .rules = .{ .decision = .{ .fields = .{ "enabled", "label" } } },
};
const Thing = zigma.Entity(domains, definition);
const Model = zigma.Framework(domains, .{ .things = .{ .Type = Thing, .definition = definition } });
const codecs = rest.defineCodecs(domains, zigma.merge(.{ rest.common_codecs, .{ .fecha = aida_rest.date_codec } }));
const names = &.{ "id", "label", "enabled", "note", "count", "approved", "date" };
const Repository = fixture.Repository(names);
const basic: Thing = .{ .id = 7, .label = "ok", .enabled = false, .note = null, .count = null, .approved = null, .date = null };
const basic_cells = &.{ "7", "ok", "f", null, null, null, null };

// El observador compara durante la llamada; no retiene slices de la fila recibida.
const Observer = struct {
    var expected: []const Thing = &.{};
    var calls: usize = 0;
    var matches: bool = true;

    fn reset(rows: []const Thing) void {
        expected = rows;
        calls = 0;
        matches = true;
    }

    fn validate(value: Thing) ?rest.BusinessRuleViolation {
        if (calls >= expected.len) {
            matches = false;
        } else {
            const wanted = expected[calls];
            const dates_match = if (value.date) |date|
                if (wanted.date) |other| std.meta.eql(date, other) else false
            else
                wanted.date == null;
            matches = matches and value.id == wanted.id and value.enabled == wanted.enabled and
                std.mem.eql(u8, value.label, wanted.label) and fixture.optionalTextEqual(value.note, wanted.note) and
                value.count == wanted.count and value.approved == wanted.approved and dates_match;
        }
        calls += 1;
        if (value.enabled and std.mem.eql(u8, value.label, "Blocked"))
            return .{ .code = "blocked", .message = "An enabled thing cannot be Blocked" };
        return null;
    }
};

const validators = rest.defineBusinessValidators(Model, .{
    .things = rest.BusinessValidator(Thing){ .validate = Observer.validate },
});
const Api = rest.Api(Model, codecs, validators);

fn post(body: []const u8) rest.Request {
    return .{ .method = .POST, .target = "/api/things", .content_type = "application/json", .body = body };
}

fn put(body: []const u8) rest.Request {
    return .{ .method = .PUT, .target = "/api/things?id=7", .content_type = "application/json", .body = body };
}

fn expectErrorResponse(response: rest.Response, status: u16, code: []const u8) !void {
    try expect(response.status == status);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    try expectText(code, parsed.value.object.get("error").?.object.get("code").?.string);
}

test "business validator input is exactly the registered concrete entity" {
    try expect(Model.Row("things") == Thing);
    try expect(@FieldType(rest.BusinessValidator(Thing), "validate") == *const fn (Thing) ?rest.BusinessRuleViolation);
    Observer.reset(&.{basic});
    try expect(validators.things.validate(basic) == null);
    try expect(Observer.calls == 1 and Observer.matches);
}

test "model retains rule metadata without Projection or RuleInput factories" {
    try expect(!@hasDecl(Model, "Projection"));
    try expect(!@hasDecl(Model, "RuleInput"));
    try expectText("enabled", Model.info.things.rules.decision.fields[0]);
    try expectText("label", Model.info.things.rules.decision.fields[1]);
    const patch: Model.Patch("things") = .{ .approved = .{ .set = null } };
    const filters: Model.Filters("things") = .{ .enabled = false };
    try expect(patch.approved.set == null and filters.enabled.? == false);
}

test "POST supplies real scalars and Fecha while preserving textual repository parameters" {
    var wanted = basic;
    wanted.note = "null";
    wanted.count = 0;
    wanted.approved = false;
    wanted.date = .{ .@"año" = 2024, .mes = 2, .@"día" = 29 };
    Observer.reset(&.{wanted});
    var repository = Repository{ .expected_parameters = &.{
        .{ .name = "id", .value = "7" },
        .{ .name = "label", .value = "ok" },
        .{ .name = "enabled", .value = "false" },
        .{ .name = "note", .value = "null" },
        .{ .name = "count", .value = "0" },
        .{ .name = "approved", .value = "false" },
        .{ .name = "date", .value = "2024-02-29" },
    } };
    var api = Api.init(.{});
    const response = try api.handle(allocator, &repository, post(
        "{\"id\":7,\"label\":\"ok\",\"enabled\":false,\"note\":\"null\",\"count\":0,\"approved\":false,\"date\":{\"año\":2024,\"mes\":2,\"día\":29}}",
    ));
    defer allocator.free(response.body);
    try expect(response.status == 201);
    try expect(Observer.calls == 1 and Observer.matches);
    try expect(repository.insert_calls == 1 and repository.parameters_match and repository.deinit_calls == 1);
    try expectText("{\"id\":7,\"label\":\"ok\",\"enabled\":false,\"note\":\"null\",\"count\":0,\"approved\":false,\"date\":{\"año\":2024,\"mes\":2,\"día\":29}}", response.body);
}

test "POST completes omitted nullable fields before typed validation" {
    Observer.reset(&.{basic});
    var repository = Repository{};
    var api = Api.init(.{});
    const response = try api.handle(allocator, &repository, post("{\"id\":7,\"label\":\"ok\",\"enabled\":false}"));
    defer allocator.free(response.body);
    try expect(response.status == 201 and Observer.calls == 1 and Observer.matches);
    try expectText("{\"id\":7,\"label\":\"ok\",\"enabled\":false,\"note\":null,\"count\":null,\"approved\":null,\"date\":null}", response.body);
}

test "POST returns a stable business violation without writing" {
    var wanted = basic;
    wanted.label = "Blocked";
    wanted.enabled = true;
    Observer.reset(&.{wanted});
    var repository = Repository{};
    var api = Api.init(.{});
    const response = try api.handle(allocator, &repository, post("{\"id\":7,\"label\":\"Blocked\",\"enabled\":true}"));
    defer allocator.free(response.body);
    try expectErrorResponse(response, 422, "blocked");
    try expectText("{\"error\":{\"code\":\"blocked\",\"message\":\"An enabled thing cannot be Blocked\"}}", response.body);
    try expect(Observer.calls == 1 and Observer.matches and repository.insert_calls == 0);
}

test "PUT validates a changed dependency with the rest of the stored typed row" {
    const cells = &.{ "7", "Blocked", "f", "null", "0", "f", "2024-02-29" };
    const wanted: Thing = .{
        .id = 7,
        .label = "Blocked",
        .enabled = true,
        .note = "null",
        .count = 0,
        .approved = false,
        .date = .{ .@"año" = 2024, .mes = 2, .@"día" = 29 },
    };
    Observer.reset(&.{wanted});
    var repository = Repository{ .rows = &.{cells} };
    var api = Api.init(.{});
    const response = try api.handle(allocator, &repository, put("{\"enabled\":true}"));
    defer allocator.free(response.body);
    try expectErrorResponse(response, 422, "blocked");
    try expect(Observer.calls == 1 and Observer.matches);
    try expect(repository.select_calls == 1 and repository.update_calls == 0 and repository.deinit_calls == 1);
}

test "PUT can clear nullable fields without clearing omitted values" {
    var wanted = basic;
    wanted.count = 0;
    Observer.reset(&.{wanted});
    var repository = Repository{
        .rows = &.{&.{ "7", "ok", "f", "old", "0", "t", "2024-02-29" }},
        .expected_parameters = &.{
            .{ .name = "note", .value = null },
            .{ .name = "approved", .value = null },
            .{ .name = "date", .value = null },
        },
    };
    var api = Api.init(.{});
    const response = try api.handle(allocator, &repository, put("{\"note\":null,\"approved\":null,\"date\":null}"));
    defer allocator.free(response.body);
    try expect(response.status == 200 and Observer.calls == 1 and Observer.matches);
    try expect(repository.parameters_match and repository.update_calls == 1 and repository.deinit_calls == 2);
}

test "PUT validates all selected rows before the first write" {
    var first = basic;
    first.enabled = true;
    var second = first;
    second.id = 8;
    second.label = "Blocked";
    Observer.reset(&.{ first, second });
    var repository = Repository{ .rows = &.{ basic_cells, &.{ "8", "Blocked", "f", null, null, null, null } } };
    var api = Api.init(.{});
    const response = try api.handle(allocator, &repository, put("{\"enabled\":true}"));
    defer allocator.free(response.body);
    try expectErrorResponse(response, 422, "blocked");
    try expect(Observer.calls == 2 and Observer.matches);
    try expect(repository.update_calls == 0 and repository.deinit_calls == 1);
}

test "PUT assigns typed values to formerly null fields" {
    var wanted = basic;
    wanted.note = "null";
    wanted.count = 0;
    wanted.approved = false;
    wanted.date = .{ .@"año" = 2024, .mes = 2, .@"día" = 29 };
    Observer.reset(&.{wanted});
    var repository = Repository{ .rows = &.{basic_cells} };
    var api = Api.init(.{});
    const response = try api.handle(allocator, &repository, put(
        "{\"note\":\"null\",\"count\":0,\"approved\":false,\"date\":{\"año\":2024,\"mes\":2,\"día\":29}}",
    ));
    defer allocator.free(response.body);
    try expect(response.status == 200 and Observer.calls == 1 and Observer.matches);
    try expect(repository.update_calls == 1 and repository.deinit_calls == 2);
}

test "PUT with no matching rows keeps its empty success response" {
    Observer.reset(&.{});
    var repository = Repository{};
    var api = Api.init(.{});
    const response = try api.handle(allocator, &repository, put("{\"enabled\":true}"));
    defer allocator.free(response.body);
    try expect(response.status == 200);
    try expectText("[]", response.body);
    try expect(Observer.calls == 0 and repository.update_calls == 1 and repository.deinit_calls == 2);
}

test "entities without validators do not select or run descriptive rules" {
    Observer.reset(&.{});
    var repository = Repository{ .rows = &.{basic_cells}, .empty_write_result = true };
    var api = rest.Api(Model, codecs, .{}).init(.{});
    const response = try api.handle(allocator, &repository, put("{\"label\":\"Blocked\",\"enabled\":true}"));
    defer allocator.free(response.body);
    try expect(response.status == 200);
    try expect(repository.select_calls == 0 and repository.update_calls == 1 and Observer.calls == 0);
}

test "GET and DELETE do not invoke an entity business validator" {
    Observer.reset(&.{});
    var repository = Repository{ .rows = &.{basic_cells} };
    var api = Api.init(.{});
    for ([_]rest.Method{ .GET, .DELETE }) |method| {
        const response = try api.handle(allocator, &repository, .{ .method = method, .target = "/api/things?id=7" });
        defer allocator.free(response.body);
        try expect(response.status == 200);
    }
    try expect(Observer.calls == 0 and repository.select_calls == 1 and repository.deinit_calls == 2);
}

test "invalid stored scalars and forbidden nulls fail before the callback and update" {
    const invalid_rows = [_][]const ?[]const u8{
        &.{ "secret-invalid-id", "ok", "f", null, null, null, null },
        &.{ "7", "ok", "secret-invalid-bool", null, null, null, null },
        &.{ "7", "ok", null, null, null, null, null },
        &.{ "7", "ok", "f", null, null, null, "secret-invalid-date" },
    };
    for (invalid_rows) |cells| {
        Observer.reset(&.{});
        var repository = Repository{ .rows = &.{cells} };
        var api = Api.init(.{});
        const response = try api.handle(allocator, &repository, put("{\"note\":\"changed\"}"));
        defer allocator.free(response.body);
        try expectErrorResponse(response, 500, "business_validation_error");
        try expect(std.mem.indexOf(u8, response.body, "secret") == null);
        try expect(Observer.calls == 0 and repository.update_calls == 0 and repository.deinit_calls == 1);
    }
}

test "malformed repository columns and row widths keep the shape error" {
    const configurations = [_]Repository{
        .{ .columns = &.{ "label", "id", "enabled", "note", "count", "approved", "date" }, .rows = &.{basic_cells} },
        .{ .columns = &.{"id"}, .rows = &.{basic_cells} },
        .{ .rows = &.{&.{"7"}} },
    };
    for (configurations) |configuration| {
        Observer.reset(&.{});
        var repository = configuration;
        var api = Api.init(.{});
        const response = try api.handle(allocator, &repository, put("{\"note\":null}"));
        defer allocator.free(response.body);
        try expectErrorResponse(response, 500, "invalid_repository_result");
        try expect(Observer.calls == 0 and repository.update_calls == 0 and repository.deinit_calls == 1);
    }
}

fn wrongIntegerJson(_: std.mem.Allocator, _: []const u8) rest.CodecError!std.json.Value {
    return .{ .bool = true };
}

fn memoryFailure(_: std.mem.Allocator, _: []const u8) rest.CodecError!std.json.Value {
    return error.OutOfMemory;
}

fn ApiWithIntegerOutput(comptime convert: @FieldType(rest.Codec, "postgresToJson")) type {
    const replacement = rest.Codec{
        .queryToPostgres = rest.integer_codec.queryToPostgres,
        .jsonToPostgres = rest.integer_codec.jsonToPostgres,
        .postgresToJson = convert,
    };
    return rest.Api(Model, zigma.merge(.{ codecs, .{ .integer = replacement } }), validators);
}

test "codec JSON incompatible with the domain becomes a sanitized internal error" {
    Observer.reset(&.{});
    var repository = Repository{};
    var api = ApiWithIntegerOutput(wrongIntegerJson).init(.{});
    const response = try api.handle(allocator, &repository, post("{\"id\":7,\"label\":\"ok\",\"enabled\":false}"));
    defer allocator.free(response.body);
    try expectErrorResponse(response, 500, "business_validation_error");
    try expect(repository.insert_calls == 0 and Observer.calls == 0);
}

test "POST propagates decoder OutOfMemory without writing or calling the rule" {
    Observer.reset(&.{});
    var repository = Repository{};
    var api = ApiWithIntegerOutput(memoryFailure).init(.{});
    try std.testing.expectError(error.OutOfMemory, api.handle(allocator, &repository, post("{\"id\":7,\"label\":\"ok\",\"enabled\":false}")));
    try expect(repository.insert_calls == 0 and Observer.calls == 0);
}

test "PUT propagates decoder OutOfMemory and releases the selected result" {
    Observer.reset(&.{});
    var repository = Repository{ .rows = &.{basic_cells} };
    var api = ApiWithIntegerOutput(memoryFailure).init(.{});
    try std.testing.expectError(error.OutOfMemory, api.handle(allocator, &repository, put("{\"note\":null}")));
    try expect(repository.select_calls == 1 and repository.update_calls == 0 and repository.deinit_calls == 1 and Observer.calls == 0);
}

test "AIDA REST invokes the concrete docente rule with the same public violation" {
    var repository = fixture.Repository(&.{
        "docente", "apellido", "nombres", "cargo", "email", "email_alternativo", "jefe", "telefono", "experiencia", "esImportador",
    }){};
    var api = aida_rest.Api.init(.{});
    const response = try api.handle(allocator, &repository, .{
        .method = .POST,
        .target = "/api/docentes",
        .content_type = "application/json",
        .body = "{\"docente\":\"d1\",\"nombres\":\"Ada\",\"cargo\":\"teorico\",\"experiencia\":4}",
    });
    defer allocator.free(response.body);
    try expectErrorResponse(response, 422, "teorico_requires_five_years_experience");
    try expectText("{\"error\":{\"code\":\"teorico_requires_five_years_experience\",\"message\":\"A docente with cargo 'teorico' requires at least 5 years of experiencia\"}}", response.body);
    try expect(repository.insert_calls == 0);
    const validate: *const fn (aida.Docente) aida.DocenteValidationError!void = aida.validarDocente;
    try validate(.{
        .docente = "d1",
        .apellido = null,
        .nombres = "Ada",
        .cargo = "teorico",
        .email = null,
        .email_alternativo = null,
        .jefe = null,
        .telefono = null,
        .experiencia = 5,
        .esImportador = null,
    });
}
