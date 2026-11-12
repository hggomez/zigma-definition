//! Validación HTTP de edad con un día de referencia fijo y repositorio observable.
const std = @import("std");
const aida = @import("aida");
const aida_rest = @import("aida_rest");
const rest = @import("zigma_rest");
const fixture = @import("fixtures/validation_repository.zig");
const allocator = std.testing.allocator;
const names = @typeInfo(@TypeOf(aida.Model.info.docentes.fields)).@"struct".field_names;
const Repository = fixture.Repository(names);
const today: aida.Fecha = .{ .@"año" = 2026, .mes = 10, .@"día" = 28 };

fn cells(id: []const u8, cargo: ?[]const u8, birth: ?[]const u8) [11]?[]const u8 {
    return .{ id, null, "Ada", cargo, null, null, null, null, "5", null, birth };
}

fn request(method: rest.Method, body: []const u8) rest.Request {
    return .{
        .method = method,
        .target = if (method == .POST) "/api/docentes" else "/api/docentes?experiencia=5",
        .body = body,
        .content_type = "application/json",
    };
}

fn handle(api: *aida_rest.Api, repository: *Repository, req: rest.Request) !rest.Response {
    return api.handle(allocator, repository, req, .{ .today = today });
}

fn expectViolation(response: rest.Response, code: []const u8, message: []const u8) !void {
    try std.testing.expect(response.status == 422);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.body, .{});
    defer parsed.deinit();
    const violation = parsed.value.object.get("error").?.object;
    try std.testing.expectEqualStrings(code, violation.get("code").?.string);
    try std.testing.expectEqualStrings(message, violation.get("message").?.string);
}

test "POST rechaza un docente teórico menor de treinta años sin insertar" {
    var repository = Repository{};
    var api = aida_rest.Api.init(.{});
    const response = try handle(&api, &repository, request(.POST, "{\"docente\":\"d1\",\"nombres\":\"Ada\",\"cargo\":\"teorico\",\"experiencia\":5,\"fecha_nacimiento\":{\"año\":1996,\"mes\":10,\"día\":29}}"));
    defer allocator.free(response.body);
    try expectViolation(response, "teorico_requires_thirty_years", "A docente with cargo 'teorico' must be at least 30 years old");
    try std.testing.expect(repository.insert_calls == 0 and repository.select_calls == 0);
}

test "POST distingue la fecha de nacimiento ausente de la experiencia insuficiente" {
    for ([_][]const u8{
        "{\"docente\":\"d1\",\"nombres\":\"Ada\",\"cargo\":\"teorico\",\"experiencia\":5}",
        "{\"docente\":\"d1\",\"nombres\":\"Ada\",\"cargo\":\"teorico\",\"experiencia\":5,\"fecha_nacimiento\":null}",
    }) |body| {
        var repository = Repository{};
        var api = aida_rest.Api.init(.{});
        const response = try handle(&api, &repository, request(.POST, body));
        defer allocator.free(response.body);
        try expectViolation(response, "teorico_requires_birth_date", "A docente with cargo 'teorico' requires fecha_nacimiento");
        try std.testing.expect(repository.insert_calls == 0);
    }
}

test "POST distingue el nacimiento futuro de los errores de calendario y experiencia" {
    var repository = Repository{};
    var api = aida_rest.Api.init(.{});
    const response = try handle(&api, &repository, request(.POST, "{\"docente\":\"d1\",\"nombres\":\"Ada\",\"cargo\":\"teorico\",\"experiencia\":5,\"fecha_nacimiento\":{\"año\":2027,\"mes\":1,\"día\":1}}"));
    defer allocator.free(response.body);
    try expectViolation(response, "birth_date_in_future", "A docente's birth date cannot be in the future");
    try std.testing.expect(repository.insert_calls == 0);
}

test "POST acepta el trigésimo cumpleaños exacto y conserva los parámetros ISO" {
    const expected_cells = cells("d1", "teorico", "1996-10-28");
    var parameters: [names.len]rest.FieldValue = undefined;
    for (names, expected_cells, 0..) |name, value, i| parameters[i] = .{ .name = name, .value = value };
    var repository = Repository{ .expected_parameters = &parameters };
    var api = aida_rest.Api.init(.{});
    const response = try handle(&api, &repository, request(.POST, "{\"docente\":\"d1\",\"nombres\":\"Ada\",\"cargo\":\"teorico\",\"experiencia\":5,\"fecha_nacimiento\":{\"año\":1996,\"mes\":10,\"día\":28}}"));
    defer allocator.free(response.body);
    try std.testing.expect(response.status == 201 and repository.insert_calls == 1 and repository.deinit_calls == 1 and repository.parameters_match);
    try std.testing.expectEqualStrings("{\"docente\":\"d1\",\"apellido\":null,\"nombres\":\"Ada\",\"cargo\":\"teorico\",\"email\":null,\"email_alternativo\":null,\"jefe\":null,\"telefono\":null,\"experiencia\":5,\"esImportador\":null,\"fecha_nacimiento\":{\"año\":1996,\"mes\":10,\"día\":28}}", response.body);
}

test "PUT que cambia solo el cargo usa el nacimiento almacenado y no escribe si se rechaza" {
    const row = cells("d1", "practico", "1996-10-29");
    var repository = Repository{ .rows = &.{&row} };
    var api = aida_rest.Api.init(.{});
    const response = try handle(&api, &repository, request(.PUT, "{\"cargo\":\"teorico\"}"));
    defer allocator.free(response.body);
    try expectViolation(response, "teorico_requires_thirty_years", "A docente with cargo 'teorico' must be at least 30 years old");
    try std.testing.expect(repository.select_calls == 1 and repository.update_calls == 0 and repository.deinit_calls == 1);
}

test "PUT que cambia o borra el nacimiento usa el cargo almacenado" {
    for ([_][]const u8{ "{\"fecha_nacimiento\":null}", "{\"fecha_nacimiento\":{\"año\":1996,\"mes\":10,\"día\":29}}" }, 0..) |body, i| {
        const row = cells("d1", "teorico", "1996-10-28");
        var repository = Repository{ .rows = &.{&row} };
        var api = aida_rest.Api.init(.{});
        const response = try handle(&api, &repository, request(.PUT, body));
        defer allocator.free(response.body);
        if (i == 0) {
            try expectViolation(response, "teorico_requires_birth_date", "A docente with cargo 'teorico' requires fecha_nacimiento");
        } else {
            try expectViolation(response, "teorico_requires_thirty_years", "A docente with cargo 'teorico' must be at least 30 years old");
        }
        try std.testing.expect(repository.update_calls == 0 and repository.deinit_calls == 1);
    }
}

test "PUT valida todos los docentes seleccionados antes de escribir alguno" {
    const first = cells("d1", "practico", "1996-10-28");
    const second = cells("d2", "practico", "1996-10-29");
    var repository = Repository{ .rows = &.{ &first, &second } };
    var api = aida_rest.Api.init(.{});
    const response = try handle(&api, &repository, request(.PUT, "{\"cargo\":\"teorico\"}"));
    defer allocator.free(response.body);
    try expectViolation(response, "teorico_requires_thirty_years", "A docente with cargo 'teorico' must be at least 30 years old");
    try std.testing.expect(repository.update_calls == 0 and repository.deinit_calls == 1);
}

test "Un docente no teórico puede omitir el nacimiento y el error de experiencia conserva su mensaje" {
    var repository = Repository{};
    var api = aida_rest.Api.init(.{});
    const accepted = try handle(&api, &repository, request(.POST, "{\"docente\":\"d1\",\"nombres\":\"Ada\",\"cargo\":\"practico\"}"));
    defer allocator.free(accepted.body);
    try std.testing.expect(accepted.status == 201);
    const rejected = try handle(&api, &repository, request(.POST, "{\"docente\":\"d2\",\"nombres\":\"Ada\",\"cargo\":\"teorico\",\"experiencia\":4}"));
    defer allocator.free(rejected.body);
    try expectViolation(rejected, "teorico_requires_five_years_experience", "A docente with cargo 'teorico' requires at least 5 years of experiencia");
    try std.testing.expect(repository.insert_calls == 1);
}

test "Los errores de calendario conservan el estado 400 y GET no revalida reglas de negocio" {
    const row = cells("d1", "teorico", "1996-10-29");
    var repository = Repository{ .rows = &.{&row} };
    var api = aida_rest.Api.init(.{});
    const invalid = try handle(&api, &repository, request(.PUT, "{\"fecha_nacimiento\":{\"año\":2025,\"mes\":2,\"día\":30}}"));
    defer allocator.free(invalid.body);
    try std.testing.expect(invalid.status == 400 and repository.select_calls == 0 and repository.update_calls == 0);
    const read = try handle(&api, &repository, request(.GET, ""));
    defer allocator.free(read.body);
    try std.testing.expect(read.status == 200 and repository.deinit_calls == 1);
}
