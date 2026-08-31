const std = @import("std");
const zigma = @import("zigma");
const rest = @import("zigma_rest");
const postgres_crud = @import("zigma_postgres_crud");

const fields = zigma.record(zigma.common_type_defs, .{
    .id = .{ .type = "integer" },
    .name = .{ .type = "text", .nullable = false },
    .note = .{ .type = "text" },
});
const things = zigma.defineEntity(.{ .pk = .{"id"}, .fields = fields });

const quoted_fields = zigma.record(zigma.common_type_defs, .{
    .@"id\"part" = .{ .type = "text" },
});
const quoted = zigma.defineEntity(.{ .pk = .{"id\"part"}, .fields = quoted_fields });

const entity_defs = zigma.defineEntities(.{
    .things = things,
    .@"quoted\"table" = quoted,
});

const FakeConnection = struct {
    allocator: std.mem.Allocator,
    sql: []const u8 = "",
    parameters: []const ?[]const u8 = &.{},
    next_error: ?Error = null,
    sql_state: ?[]const u8 = null,

    const Error = error{ OutOfMemory, NotConnected, ConnectionFailed, PostgresError };

    pub fn queryParams(
        self: *FakeConnection,
        allocator: std.mem.Allocator,
        sql: []const u8,
        parameters: []const ?[]const u8,
    ) Error!rest.QueryResult {
        if (self.next_error) |err| return err;
        self.sql = self.allocator.dupe(u8, sql) catch return error.OutOfMemory;
        const copied = self.allocator.alloc(?[]const u8, parameters.len) catch return error.OutOfMemory;
        for (parameters, 0..) |parameter, index|
            copied[index] = if (parameter) |value| self.allocator.dupe(u8, value) catch return error.OutOfMemory else null;
        self.parameters = copied;
        return .{
            .allocator = allocator,
            .columns = allocator.alloc([]const u8, 0) catch return error.OutOfMemory,
            .rows = allocator.alloc([]const ?[]const u8, 0) catch return error.OutOfMemory,
        };
    }

    pub fn lastSqlState(self: *const FakeConnection) ?[]const u8 {
        return self.sql_state;
    }
};

const Repository = postgres_crud.Repository(entity_defs);

fn expectParameter(actual: ?[]const u8, expected: ?[]const u8) !void {
    if (expected) |bytes| {
        try std.testing.expect(actual != null);
        try std.testing.expectEqualStrings(bytes, actual.?);
    } else try std.testing.expect(actual == null);
}

test "SELECT uses canonical filter order and separate parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var connection = FakeConnection{ .allocator = arena.allocator() };
    var repository = Repository.init(&connection);

    var result = try repository.select(arena.allocator(), "things", &.{
        .{ .name = "name", .value = "Robert'); DROP TABLE things;--" },
        .{ .name = "id", .value = "7" },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "SELECT * FROM \"things\" WHERE \"id\" = $1 AND \"name\" = $2",
        connection.sql,
    );
    try std.testing.expectEqual(@as(usize, 2), connection.parameters.len);
    try expectParameter(connection.parameters[0], "7");
    try expectParameter(connection.parameters[1], "Robert'); DROP TABLE things;--");
    try std.testing.expect(std.mem.indexOf(u8, connection.sql, "DROP TABLE") == null);
}

test "INSERT emits canonical columns, nullable parameter and RETURNING" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var connection = FakeConnection{ .allocator = arena.allocator() };
    var repository = Repository.init(&connection);

    var result = try repository.insert(arena.allocator(), "things", &.{
        .{ .name = "note", .value = null },
        .{ .name = "name", .value = "Alice" },
        .{ .name = "id", .value = "7" },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "INSERT INTO \"things\" (\"id\", \"name\", \"note\") VALUES ($1, $2, $3) RETURNING *",
        connection.sql,
    );
    try expectParameter(connection.parameters[0], "7");
    try expectParameter(connection.parameters[1], "Alice");
    try expectParameter(connection.parameters[2], null);
}

test "UPDATE numbers canonical values before canonical filters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var connection = FakeConnection{ .allocator = arena.allocator() };
    var repository = Repository.init(&connection);

    var result = try repository.update(arena.allocator(), "things", &.{
        .{ .name = "note", .value = null },
        .{ .name = "name", .value = "Updated" },
    }, &.{
        .{ .name = "name", .value = "Old" },
        .{ .name = "id", .value = "7" },
    });
    defer result.deinit();

    try std.testing.expectEqualStrings(
        "UPDATE \"things\" SET \"name\" = $1, \"note\" = $2 WHERE \"id\" = $3 AND \"name\" = $4 RETURNING *",
        connection.sql,
    );
    try expectParameter(connection.parameters[0], "Updated");
    try expectParameter(connection.parameters[1], null);
    try expectParameter(connection.parameters[2], "7");
    try expectParameter(connection.parameters[3], "Old");
}

test "DELETE is parameterized and identifiers are escaped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var connection = FakeConnection{ .allocator = arena.allocator() };
    var repository = Repository.init(&connection);

    var deleted = try repository.delete(arena.allocator(), "things", &.{.{ .name = "id", .value = "7" }});
    deleted.deinit();
    try std.testing.expectEqualStrings(
        "DELETE FROM \"things\" WHERE \"id\" = $1 RETURNING *",
        connection.sql,
    );

    var selected = try repository.select(arena.allocator(), "quoted\"table", &.{.{ .name = "id\"part", .value = "x" }});
    selected.deinit();
    try std.testing.expectEqualStrings(
        "SELECT * FROM \"quoted\"\"table\" WHERE \"id\"\"part\" = $1",
        connection.sql,
    );
}

test "SQLSTATE class 23 maps to conflict and connection failure to unavailable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var connection = FakeConnection{
        .allocator = arena.allocator(),
        .next_error = error.PostgresError,
        .sql_state = "23505",
    };
    var repository = Repository.init(&connection);
    try std.testing.expectError(
        error.Conflict,
        repository.delete(arena.allocator(), "things", &.{.{ .name = "id", .value = "7" }}),
    );

    connection.next_error = error.ConnectionFailed;
    try std.testing.expectError(
        error.Unavailable,
        repository.select(arena.allocator(), "things", &.{}),
    );

    connection.next_error = error.PostgresError;
    connection.sql_state = "08006";
    try std.testing.expectError(
        error.Unavailable,
        repository.select(arena.allocator(), "things", &.{}),
    );
}
