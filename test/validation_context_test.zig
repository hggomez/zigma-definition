//! Contexto de aplicación tipado, explícito y compartido por una solicitud.
const std = @import("std");
const zigma = @import("zigma");
const rest = @import("zigma_rest");
const aida = @import("aida");
const aida_rest = @import("aida_rest");
const fixture = @import("fixtures/validation_repository.zig");
const allocator = std.testing.allocator;
const Context = struct { minimum: i64, request_id: []const u8 };
const definition = .{ .pk = .{"id"}, .fields = zigma.record(zigma.common_type_defs, .{
    .id = .{ .type = "integer" },
    .score = .{ .type = "integer", .nullable = false },
}) };
const Thing = zigma.Entity(zigma.common_type_defs, definition);
const Model = zigma.Framework(zigma.common_type_defs, .{ .things = .{ .Type = Thing, .definition = definition } });
const Repository = fixture.Repository(&.{ "id", "score" });
const Observer = struct {
    var wanted: Context = .{ .minimum = 30, .request_id = "request-1" };
    var calls: usize = 0;
    var matches: bool = true;

    fn validate(row: Thing, context: Context) ?rest.BusinessRuleViolation {
        matches = matches and context.minimum == wanted.minimum and std.mem.eql(u8, context.request_id, wanted.request_id);
        calls += 1;
        if (row.score < context.minimum) return .{ .code = "below_minimum", .message = "Score is below the request minimum" };
        return null;
    }

    fn reset(context: Context) void {
        wanted = context;
        calls = 0;
        matches = true;
    }
};
const validators = rest.defineBusinessValidators(Model, .{
    .things = rest.BusinessValidator(Thing, Context){ .validate = Observer.validate },
});
const Api = rest.Api(Model, rest.common_codecs, validators);

test "business validators and Api expose the exact application context type" {
    try std.testing.expect(Api.ValidationContext == Context);
    try std.testing.expect(@FieldType(rest.BusinessValidator(Thing, Context), "validate") == *const fn (Thing, Context) ?rest.BusinessRuleViolation);
}

test "POST receives a context which can change between requests" {
    var repository = Repository{};
    var api = Api.init(.{});
    const req: rest.Request = .{ .method = .POST, .target = "/api/things", .content_type = "application/json", .body = "{\"id\":1,\"score\":29}" };
    Observer.reset(.{ .minimum = 29, .request_id = "before-midnight" });
    const first = try api.handle(allocator, &repository, req, Observer.wanted);
    defer allocator.free(first.body);
    try std.testing.expect(first.status == 201 and Observer.calls == 1 and Observer.matches);
    Observer.reset(.{ .minimum = 30, .request_id = "after-midnight" });
    const second = try api.handle(allocator, &repository, req, Observer.wanted);
    defer allocator.free(second.body);
    try std.testing.expect(second.status == 422 and Observer.calls == 1 and Observer.matches);
    try std.testing.expect(repository.insert_calls == 1);
}

test "all PUT rows receive the same context and no row is written after a rejection" {
    Observer.reset(.{ .minimum = 30, .request_id = "one-request" });
    var repository = Repository{ .rows = &.{ &.{ "1", "30" }, &.{ "2", "29" } } };
    var api = Api.init(.{});
    const response = try api.handle(allocator, &repository, .{
        .method = .PUT,
        .target = "/api/things?score=29",
        .content_type = "application/json",
        .body = "{\"score\":29}",
    }, Observer.wanted);
    defer allocator.free(response.body);
    // El rechazo inicial corta la validación; el segundo PUT comprueba ambas filas.
    try std.testing.expect(response.status == 422 and Observer.calls == 1 and Observer.matches);
    try std.testing.expect(repository.select_calls == 1 and repository.update_calls == 0);
    Observer.reset(.{ .minimum = 29, .request_id = "all-rows" });
    const accepted = try api.handle(allocator, &repository, .{
        .method = .PUT,
        .target = "/api/things?score=29",
        .content_type = "application/json",
        .body = "{\"score\":30}",
    }, Observer.wanted);
    defer allocator.free(accepted.body);
    try std.testing.expect(accepted.status == 200 and Observer.calls == 2 and Observer.matches);
    try std.testing.expect(repository.update_calls == 1 and repository.deinit_calls == 3);
}

test "GET and DELETE do not execute contextual validators" {
    Observer.reset(.{ .minimum = 100, .request_id = "read" });
    var repository = Repository{ .rows = &.{&.{ "1", "29" }} };
    var api = Api.init(.{});
    for ([_]rest.Method{ .GET, .DELETE }) |method| {
        const response = try api.handle(allocator, &repository, .{ .method = method, .target = "/api/things?id=1" }, Observer.wanted);
        defer allocator.free(response.body);
        try std.testing.expect(response.status == 200);
    }
    try std.testing.expect(Observer.calls == 0 and repository.deinit_calls == 2);
}

test "an API without validators has a void context and no preparatory SELECT" {
    const NoRulesApi = rest.Api(Model, rest.common_codecs, .{});
    try std.testing.expect(NoRulesApi.ValidationContext == void);
    var api = NoRulesApi.init(.{});
    var repository = Repository{ .rows = &.{&.{ "1", "29" }} };
    const response = try api.handle(allocator, &repository, .{
        .method = .PUT,
        .target = "/api/things?id=1",
        .content_type = "application/json",
        .body = "{\"score\":30}",
    }, {});
    defer allocator.free(response.body);
    try std.testing.expect(response.status == 200 and repository.select_calls == 0 and repository.update_calls == 1);
}

test "AIDA context converts UTC timestamps at the Argentina civil day boundary" {
    // 2026-10-28 02:59:59 y 03:00:00 UTC: medianoche en UTC-03:00.
    const before = try aida_rest.contextFromTimestamp(1793156399);
    const after = try aida_rest.contextFromTimestamp(1793156400);
    try std.testing.expect(std.meta.eql(before.today, aida.Fecha{ .@"año" = 2026, .mes = 10, .@"día" = 27 }));
    try std.testing.expect(std.meta.eql(after.today, aida.Fecha{ .@"año" = 2026, .mes = 10, .@"día" = 28 }));
}

test "AIDA context conversion crosses year and leap day boundaries" {
    const cases = [_]struct { seconds: i64, expected: aida.Fecha }{
        .{ .seconds = 1798772400, .expected = .{ .@"año" = 2027, .mes = 1, .@"día" = 1 } },
        .{ .seconds = 1709175600, .expected = .{ .@"año" = 2024, .mes = 2, .@"día" = 29 } },
        .{ .seconds = 1709262000, .expected = .{ .@"año" = 2024, .mes = 3, .@"día" = 1 } },
        .{ .seconds = -62135586000, .expected = .{ .@"año" = 1, .mes = 1, .@"día" = 1 } },
        .{ .seconds = -2208978000, .expected = .{ .@"año" = 1900, .mes = 1, .@"día" = 1 } },
        .{ .seconds = 253402311599, .expected = .{ .@"año" = 9999, .mes = 12, .@"día" = 31 } },
    };
    for (cases) |case| {
        const context = try aida_rest.contextFromTimestamp(case.seconds);
        try std.testing.expect(std.meta.eql(context.today, case.expected));
    }
}

test "AIDA context rejects timestamps outside Fecha without overflow" {
    try std.testing.expectError(error.InvalidDate, aida_rest.contextFromTimestamp(-62135586001));
    try std.testing.expectError(error.InvalidDate, aida_rest.contextFromTimestamp(253402311600));
    try std.testing.expectError(error.InvalidDate, aida_rest.contextFromTimestamp(std.math.minInt(i64)));
    try std.testing.expectError(error.InvalidDate, aida_rest.contextFromTimestamp(std.math.maxInt(i64)));
}
