const std = @import("std");
const zigma = @import("zigma");
const aida = @import("aida");
const postgres_ddl = @import("zigma_postgres_ddl");
const postgres_executor = @import("zigma_postgres_executor");

const type_mappings = postgres_ddl.defineTypeMappings(zigma.merge(.{
    postgres_ddl.common_type_mappings,
    .{
        .fecha = postgres_ddl.TypeMapping{ .sql_type = "DATE" },
        .email = postgres_ddl.TypeMapping{ .sql_type = "TEXT" },
    },
}));

const schema_ddl = postgres_ddl.createSchemaDdl(aida.entity_defs, type_mappings);

const Event = enum {
    begin,
    exec,
    commit,
    rollback,
};

const FakeConnection = struct {
    events: [4]Event = undefined,
    event_count: usize = 0,
    executed_sql: ?[]const u8 = null,
    fail_begin: bool = false,
    fail_exec: bool = false,
    fail_commit: bool = false,
    fail_rollback: bool = false,

    fn record(self: *FakeConnection, event: Event) void {
        self.events[self.event_count] = event;
        self.event_count += 1;
    }

    pub fn begin(self: *FakeConnection) error{BeginFailed}!void {
        self.record(.begin);
        if (self.fail_begin) return error.BeginFailed;
    }

    pub fn exec(self: *FakeConnection, sql: []const u8) error{ExecFailed}!void {
        self.record(.exec);
        self.executed_sql = sql;
        if (self.fail_exec) return error.ExecFailed;
    }

    pub fn commit(self: *FakeConnection) error{CommitFailed}!void {
        self.record(.commit);
        if (self.fail_commit) return error.CommitFailed;
    }

    pub fn rollback(self: *FakeConnection) error{RollbackFailed}!void {
        self.record(.rollback);
        if (self.fail_rollback) return error.RollbackFailed;
    }
};

fn expectEvents(connection: *const FakeConnection, expected: []const Event) !void {
    try std.testing.expect(connection.event_count == expected.len);
    for (expected, 0..) |event, index| {
        try std.testing.expect(connection.events[index] == event);
    }
}

test "executes the immutable generated schema in one transaction" {
    var connection = FakeConnection{};

    try postgres_executor.executeSchema(&connection, schema_ddl);

    try expectEvents(&connection, &.{ .begin, .exec, .commit });
    const executed = connection.executed_sql.?;
    try std.testing.expect(executed.ptr == schema_ddl.ptr);
    try std.testing.expect(executed.len == schema_ddl.len);
    try std.testing.expectEqualStrings(schema_ddl, executed);
}

test "does not rollback when beginning the transaction fails" {
    var connection = FakeConnection{ .fail_begin = true };

    try std.testing.expectError(
        error.BeginFailed,
        postgres_executor.executeSchema(&connection, schema_ddl),
    );

    try expectEvents(&connection, &.{.begin});
    try std.testing.expect(connection.executed_sql == null);
}

test "rolls back and does not commit when schema execution fails" {
    var connection = FakeConnection{ .fail_exec = true };

    try std.testing.expectError(
        error.ExecFailed,
        postgres_executor.executeSchema(&connection, schema_ddl),
    );

    try expectEvents(&connection, &.{ .begin, .exec, .rollback });
}

test "rolls back when commit fails" {
    var connection = FakeConnection{ .fail_commit = true };

    try std.testing.expectError(
        error.CommitFailed,
        postgres_executor.executeSchema(&connection, schema_ddl),
    );

    try expectEvents(&connection, &.{ .begin, .exec, .commit, .rollback });
}

test "preserves the schema error when rollback also fails" {
    var connection = FakeConnection{
        .fail_exec = true,
        .fail_rollback = true,
    };

    try std.testing.expectError(
        error.ExecFailed,
        postgres_executor.executeSchema(&connection, schema_ddl),
    );

    try expectEvents(&connection, &.{ .begin, .exec, .rollback });
}
