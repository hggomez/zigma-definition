const std = @import("std");
const zigma = @import("zigma");
const rest = @import("zigma_rest");

const fields = zigma.record(zigma.common_type_defs, .{
    .id = .{ .type = "integer" },
    .name = .{ .type = "text", .nullable = false },
    .active = .{ .type = "boolean", .nullable = false },
    .note = .{ .type = "text" },
});
const things = zigma.defineEntity(.{
    .pk = .{"id"},
    .fields = fields,
});
const entity_defs = zigma.defineEntities(.{ .things = things });
const codecs = rest.defineCodecs(zigma.common_type_defs, rest.common_codecs);
const TestApi = rest.Api(entity_defs, codecs);

const Operation = enum { none, select, insert, update, delete };

const FakeRepository = struct {
    operation: Operation = .none,
    entity_name: []const u8 = "",
    filters: []const rest.FieldValue = &.{},
    values: []const rest.FieldValue = &.{},
    next_error: ?rest.RepositoryError = null,
    empty: bool = false,

    fn makeResult(self: *FakeRepository, allocator: std.mem.Allocator) rest.RepositoryError!rest.QueryResult {
        const columns_source = [_][]const u8{ "id", "name", "active", "note" };
        const values_source = [_]?[]const u8{ "7", "Alice", "t", null };

        const columns = allocator.alloc([]const u8, columns_source.len) catch return error.OutOfMemory;
        for (columns_source, 0..) |column, index|
            columns[index] = allocator.dupe(u8, column) catch return error.OutOfMemory;

        const row_count: usize = if (self.empty) 0 else 1;
        const rows = allocator.alloc([]const ?[]const u8, row_count) catch return error.OutOfMemory;
        if (!self.empty) {
            const row = allocator.alloc(?[]const u8, values_source.len) catch return error.OutOfMemory;
            for (values_source, 0..) |value, index|
                row[index] = if (value) |bytes| allocator.dupe(u8, bytes) catch return error.OutOfMemory else null;
            rows[0] = row;
        }
        return .{ .allocator = allocator, .columns = columns, .rows = rows };
    }

    fn maybeFail(self: *FakeRepository) rest.RepositoryError!void {
        if (self.next_error) |err| return err;
    }

    pub fn select(
        self: *FakeRepository,
        allocator: std.mem.Allocator,
        entity_name: []const u8,
        filters: []const rest.FieldValue,
    ) rest.RepositoryError!rest.QueryResult {
        try self.maybeFail();
        self.operation = .select;
        self.entity_name = entity_name;
        self.filters = filters;
        return self.makeResult(allocator);
    }

    pub fn insert(
        self: *FakeRepository,
        allocator: std.mem.Allocator,
        entity_name: []const u8,
        values: []const rest.FieldValue,
    ) rest.RepositoryError!rest.QueryResult {
        try self.maybeFail();
        self.operation = .insert;
        self.entity_name = entity_name;
        self.values = values;
        return self.makeResult(allocator);
    }

    pub fn update(
        self: *FakeRepository,
        allocator: std.mem.Allocator,
        entity_name: []const u8,
        values: []const rest.FieldValue,
        filters: []const rest.FieldValue,
    ) rest.RepositoryError!rest.QueryResult {
        try self.maybeFail();
        self.operation = .update;
        self.entity_name = entity_name;
        self.values = values;
        self.filters = filters;
        return self.makeResult(allocator);
    }

    pub fn delete(
        self: *FakeRepository,
        allocator: std.mem.Allocator,
        entity_name: []const u8,
        filters: []const rest.FieldValue,
    ) rest.RepositoryError!rest.QueryResult {
        try self.maybeFail();
        self.operation = .delete;
        self.entity_name = entity_name;
        self.filters = filters;
        return self.makeResult(allocator);
    }
};

fn expectValue(value: rest.FieldValue, name: []const u8, expected: ?[]const u8) !void {
    try std.testing.expectEqualStrings(name, value.name);
    if (expected) |bytes| {
        try std.testing.expect(value.value != null);
        try std.testing.expectEqualStrings(bytes, value.value.?);
    } else {
        try std.testing.expect(value.value == null);
    }
}

test "routes are generated at comptime" {
    try std.testing.expectEqual(@as(usize, 1), TestApi.routes.len);
    try std.testing.expectEqualStrings("/api/things", TestApi.routes[0].path);
}

test "GET filters are decoded, validated and ordered by entity field order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var api = TestApi.init(.{});
    var repository = FakeRepository{};

    const response = try api.handle(arena.allocator(), &repository, .{
        .method = .GET,
        .target = "/api/things?name=Alice+P%C3%A9rez&id=7",
    });

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings(
        "[{\"id\":7,\"name\":\"Alice\",\"active\":true,\"note\":null}]",
        response.body,
    );
    try std.testing.expectEqual(Operation.select, repository.operation);
    try std.testing.expectEqualStrings("things", repository.entity_name);
    try std.testing.expectEqual(@as(usize, 2), repository.filters.len);
    try expectValue(repository.filters[0], "id", "7");
    try expectValue(repository.filters[1], "name", "Alice Pérez");
}

test "POST validates and normalizes a complete row" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var api = TestApi.init(.{});
    var repository = FakeRepository{};

    const response = try api.handle(arena.allocator(), &repository, .{
        .method = .POST,
        .target = "/api/things",
        .content_type = "application/json; charset=utf-8",
        .body = "{\"id\":7,\"name\":\"Alice\",\"active\":true}",
    });

    try std.testing.expectEqual(@as(u16, 201), response.status);
    try std.testing.expectEqualStrings(
        "{\"id\":7,\"name\":\"Alice\",\"active\":true,\"note\":null}",
        response.body,
    );
    try std.testing.expectEqual(Operation.insert, repository.operation);
    try std.testing.expectEqual(@as(usize, 4), repository.values.len);
    try expectValue(repository.values[0], "id", "7");
    try expectValue(repository.values[1], "name", "Alice");
    try expectValue(repository.values[2], "active", "true");
    try expectValue(repository.values[3], "note", null);
}

test "PUT is partial and DELETE requires a filter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var api = TestApi.init(.{});
    var repository = FakeRepository{ .empty = true };

    const put_response = try api.handle(arena.allocator(), &repository, .{
        .method = .PUT,
        .target = "/api/things?id=7",
        .content_type = "application/json",
        .body = "{\"note\":null}",
    });
    try std.testing.expectEqual(@as(u16, 200), put_response.status);
    try std.testing.expectEqualStrings("[]", put_response.body);
    try std.testing.expectEqual(Operation.update, repository.operation);
    try expectValue(repository.values[0], "note", null);

    const delete_response = try api.handle(arena.allocator(), &repository, .{
        .method = .DELETE,
        .target = "/api/things",
    });
    try std.testing.expectEqual(@as(u16, 400), delete_response.status);
}

test "bad routes, methods, query parameters and bodies map to exact statuses" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var api = TestApi.init(.{ .max_body_bytes = 8 });
    var repository = FakeRepository{};

    const missing = try api.handle(arena.allocator(), &repository, .{ .method = .GET, .target = "/api/missing" });
    try std.testing.expectEqual(@as(u16, 404), missing.status);
    const method = try api.handle(arena.allocator(), &repository, .{ .method = .other, .target = "/api/things" });
    try std.testing.expectEqual(@as(u16, 405), method.status);
    const duplicate = try api.handle(arena.allocator(), &repository, .{ .method = .GET, .target = "/api/things?id=1&id=2" });
    try std.testing.expectEqual(@as(u16, 400), duplicate.status);
    const unknown = try api.handle(arena.allocator(), &repository, .{ .method = .GET, .target = "/api/things?wat=1" });
    try std.testing.expectEqual(@as(u16, 400), unknown.status);
    const unsupported = try api.handle(arena.allocator(), &repository, .{
        .method = .POST,
        .target = "/api/things",
        .body = "{}",
    });
    try std.testing.expectEqual(@as(u16, 415), unsupported.status);
    const too_large = try api.handle(arena.allocator(), &repository, .{
        .method = .POST,
        .target = "/api/things",
        .content_type = "application/json",
        .body = "012345678",
    });
    try std.testing.expectEqual(@as(u16, 413), too_large.status);
}

test "mutations reject missing fields, PK updates and unsafe requests" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var api = TestApi.init(.{});
    var repository = FakeRepository{};

    const missing = try api.handle(arena.allocator(), &repository, .{
        .method = .POST,
        .target = "/api/things",
        .content_type = "application/json",
        .body = "{\"id\":7}",
    });
    try std.testing.expectEqual(@as(u16, 400), missing.status);
    const pk_update = try api.handle(arena.allocator(), &repository, .{
        .method = .PUT,
        .target = "/api/things?id=7",
        .content_type = "application/json",
        .body = "{\"id\":8}",
    });
    try std.testing.expectEqual(@as(u16, 400), pk_update.status);
    const empty_update = try api.handle(arena.allocator(), &repository, .{
        .method = .PUT,
        .target = "/api/things?id=7",
        .content_type = "application/json",
        .body = "{}",
    });
    try std.testing.expectEqual(@as(u16, 400), empty_update.status);
}

test "repository failures are hidden behind stable HTTP errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var api = TestApi.init(.{});

    var conflict_repository = FakeRepository{ .next_error = error.Conflict };
    const conflict = try api.handle(arena.allocator(), &conflict_repository, .{
        .method = .DELETE,
        .target = "/api/things?id=7",
    });
    try std.testing.expectEqual(@as(u16, 409), conflict.status);
    try std.testing.expect(std.mem.indexOf(u8, conflict.body, "constraint_conflict") != null);

    var unavailable_repository = FakeRepository{ .next_error = error.Unavailable };
    const unavailable = try api.handle(arena.allocator(), &unavailable_repository, .{
        .method = .GET,
        .target = "/api/things",
    });
    try std.testing.expectEqual(@as(u16, 503), unavailable.status);
}

test "common codecs reject malformed values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidValue, rest.integer_codec.queryToPostgres(arena.allocator(), "7 OR 1=1"));
    try std.testing.expectError(error.InvalidValue, rest.boolean_codec.queryToPostgres(arena.allocator(), "yes"));
    try std.testing.expectError(error.InvalidValue, rest.integer_codec.jsonToPostgres(arena.allocator(), .{ .string = "7" }));
}

test "handle owns scratch allocations and returns only the response body" {
    var api = TestApi.init(.{});
    var repository = FakeRepository{};
    const response = try api.handle(std.testing.allocator, &repository, .{
        .method = .GET,
        .target = "/api/things?id=7",
    });
    defer std.testing.allocator.free(response.body);
    try std.testing.expectEqual(@as(u16, 200), response.status);
}
