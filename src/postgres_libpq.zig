//! Minimal blocking libpq adapter for PostgreSQL DDL and parameterized CRUD.

const std = @import("std");
const c = @import("libpq");

pub const Error = error{
    OutOfMemory,
    NotConnected,
    AlreadyConnected,
    ConnectionFailed,
    TransactionAlreadyActive,
    SqlContainsNul,
    ConnectionStringContainsNul,
    PostgresError,
};

pub const QueryResult = struct {
    arena: std.heap.ArenaAllocator,
    columns: []const []const u8,
    rows: []const []const ?[]const u8,

    pub fn deinit(self: *QueryResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const ErrorPolicy = enum {
    replace,
    preserve,
};

/// A single blocking libpq connection.
///
/// `lastError` is owned by this value and remains valid until another
/// operation replaces it or `deinit` is called.
pub const Connection = struct {
    allocator: std.mem.Allocator,
    handle: ?*c.PGconn = null,
    last_error: ?[]u8 = null,
    sql_state: [5]u8 = undefined,
    has_sql_state: bool = false,

    pub const Result = QueryResult;

    pub fn init(allocator: std.mem.Allocator) Connection {
        return .{ .allocator = allocator };
    }

    pub fn connect(self: *Connection, conninfo: []const u8) Error!void {
        if (self.handle != null) return error.AlreadyConnected;
        if (std.mem.indexOfScalar(u8, conninfo, 0) != null)
            return error.ConnectionStringContainsNul;

        self.clearDiagnostic();
        const terminated = self.allocator.dupeSentinel(u8, conninfo, 0) catch
            return error.OutOfMemory;
        defer self.allocator.free(terminated);

        const handle = c.PQconnectdb(terminated.ptr) orelse
            return error.OutOfMemory;
        if (c.PQstatus(handle) != c.CONNECTION_OK) {
            const remember_result = self.rememberConnectionError(handle, .replace);
            c.PQfinish(handle);
            remember_result catch return error.OutOfMemory;
            return error.ConnectionFailed;
        }

        self.handle = handle;
    }

    pub fn deinit(self: *Connection) void {
        if (self.handle) |handle| c.PQfinish(handle);
        self.handle = null;
        self.clearLastError();
    }

    /// Starts a transaction only when libpq reports an idle connection.
    pub fn begin(self: *Connection) Error!void {
        const handle = try self.connectedHandle();
        if (c.PQtransactionStatus(handle) != c.PQTRANS_IDLE)
            return error.TransactionAlreadyActive;

        self.clearLastError();
        try self.execTerminated(handle, "BEGIN", .replace);
    }

    /// Executes trusted SQL. Multiple statements are accepted by `PQexec`.
    pub fn exec(self: *Connection, sql: []const u8) Error!void {
        const handle = try self.connectedHandle();
        if (std.mem.indexOfScalar(u8, sql, 0) != null)
            return error.SqlContainsNul;

        self.clearDiagnostic();
        const terminated = self.allocator.dupeSentinel(u8, sql, 0) catch
            return error.OutOfMemory;
        defer self.allocator.free(terminated);
        try self.execTerminated(handle, terminated, .replace);
    }

    /// Executes one statement using libpq text parameters and returns an
    /// owned tabular result. `null` parameters become SQL NULL and every
    /// non-null value is sent separately from the SQL string.
    pub fn queryParams(
        self: *Connection,
        allocator: std.mem.Allocator,
        sql: []const u8,
        parameters: []const ?[]const u8,
    ) Error!QueryResult {
        const handle = try self.connectedHandle();
        if (std.mem.indexOfScalar(u8, sql, 0) != null)
            return error.SqlContainsNul;

        self.clearDiagnostic();
        var temporary = std.heap.ArenaAllocator.init(self.allocator);
        defer temporary.deinit();
        const temporary_allocator = temporary.allocator();
        const terminated_sql = temporary_allocator.dupeSentinel(u8, sql, 0) catch
            return error.OutOfMemory;
        const parameter_values = temporary_allocator.alloc([*c]const u8, parameters.len) catch
            return error.OutOfMemory;
        for (parameters, 0..) |parameter, index| {
            if (parameter) |value| {
                if (std.mem.indexOfScalar(u8, value, 0) != null)
                    return error.SqlContainsNul;
                const terminated = temporary_allocator.dupeSentinel(u8, value, 0) catch
                    return error.OutOfMemory;
                parameter_values[index] = terminated.ptr;
            } else {
                parameter_values[index] = null;
            }
        }

        const result = c.PQexecParams(
            handle,
            terminated_sql.ptr,
            @intCast(parameters.len),
            null,
            if (parameter_values.len == 0) null else parameter_values.ptr,
            null,
            null,
            0,
        ) orelse {
            self.rememberConnectionError(handle, .replace) catch
                return error.OutOfMemory;
            return error.PostgresError;
        };
        defer c.PQclear(result);

        if (c.PQresultStatus(result) != c.PGRES_TUPLES_OK) {
            self.rememberResultError(handle, result, .replace) catch
                return error.OutOfMemory;
            return error.PostgresError;
        }
        return copyQueryResult(allocator, result);
    }

    pub fn commit(self: *Connection) Error!void {
        const handle = try self.connectedHandle();
        try self.execTerminated(handle, "COMMIT", .replace);
    }

    /// Rolls back while retaining the diagnostic from the operation that
    /// caused the rollback. A rollback error is stored only if no earlier
    /// PostgreSQL diagnostic exists.
    pub fn rollback(self: *Connection) Error!void {
        const handle = try self.connectedHandle();
        try self.execTerminated(handle, "ROLLBACK", .preserve);
    }

    pub fn lastError(self: *const Connection) ?[]const u8 {
        return self.last_error;
    }

    pub fn lastSqlState(self: *const Connection) ?[]const u8 {
        if (!self.has_sql_state) return null;
        return self.sql_state[0..];
    }

    fn connectedHandle(self: *Connection) Error!*c.PGconn {
        const handle = self.handle orelse return error.NotConnected;
        if (c.PQstatus(handle) != c.CONNECTION_OK) {
            self.rememberConnectionError(handle, .replace) catch
                return error.OutOfMemory;
            return error.ConnectionFailed;
        }
        return handle;
    }

    fn execTerminated(
        self: *Connection,
        handle: *c.PGconn,
        sql: [:0]const u8,
        error_policy: ErrorPolicy,
    ) Error!void {
        const result = c.PQexec(handle, sql.ptr) orelse {
            self.rememberConnectionError(handle, error_policy) catch
                return error.OutOfMemory;
            return error.PostgresError;
        };
        defer c.PQclear(result);

        if (c.PQresultStatus(result) != c.PGRES_COMMAND_OK) {
            self.rememberResultError(handle, result, error_policy) catch
                return error.OutOfMemory;
            return error.PostgresError;
        }
    }

    fn rememberResultError(
        self: *Connection,
        handle: *c.PGconn,
        result: *c.PGresult,
        policy: ErrorPolicy,
    ) std.mem.Allocator.Error!void {
        const result_message = spanCString(c.PQresultErrorMessage(result));
        if (policy == .replace or !self.has_sql_state) {
            const state = spanCString(c.PQresultErrorField(result, c.PG_DIAG_SQLSTATE));
            if (state.len == self.sql_state.len) {
                @memcpy(&self.sql_state, state);
                self.has_sql_state = true;
            }
        }
        if (result_message.len != 0)
            return self.rememberError(result_message, policy);
        return self.rememberConnectionError(handle, policy);
    }

    fn rememberConnectionError(
        self: *Connection,
        handle: *c.PGconn,
        policy: ErrorPolicy,
    ) std.mem.Allocator.Error!void {
        const message = spanCString(c.PQerrorMessage(handle));
        return self.rememberError(
            if (message.len == 0) "unknown libpq error" else message,
            policy,
        );
    }

    fn rememberError(
        self: *Connection,
        message: []const u8,
        policy: ErrorPolicy,
    ) std.mem.Allocator.Error!void {
        if (policy == .preserve and self.last_error != null) return;
        const copy = try self.allocator.dupe(u8, message);
        self.clearLastError();
        self.last_error = copy;
    }

    fn clearLastError(self: *Connection) void {
        if (self.last_error) |message| self.allocator.free(message);
        self.last_error = null;
    }

    fn clearDiagnostic(self: *Connection) void {
        self.clearLastError();
        self.has_sql_state = false;
    }
};

fn copyQueryResult(allocator: std.mem.Allocator, result: *c.PGresult) Error!QueryResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const column_count: usize = @intCast(c.PQnfields(result));
    const row_count: usize = @intCast(c.PQntuples(result));

    const columns = owned.alloc([]const u8, column_count) catch return error.OutOfMemory;
    for (columns, 0..) |*column, index| {
        const name = spanCString(c.PQfname(result, @intCast(index)));
        column.* = owned.dupe(u8, name) catch return error.OutOfMemory;
    }

    const rows = owned.alloc([]const ?[]const u8, row_count) catch return error.OutOfMemory;
    for (rows, 0..) |*row, row_index| {
        const values = owned.alloc(?[]const u8, column_count) catch return error.OutOfMemory;
        for (values, 0..) |*value, column_index| {
            if (c.PQgetisnull(result, @intCast(row_index), @intCast(column_index)) != 0) {
                value.* = null;
            } else {
                const pointer = c.PQgetvalue(result, @intCast(row_index), @intCast(column_index));
                const length: usize = @intCast(c.PQgetlength(result, @intCast(row_index), @intCast(column_index)));
                value.* = owned.dupe(u8, pointer[0..length]) catch return error.OutOfMemory;
            }
        }
        row.* = values;
    }
    return .{ .arena = arena, .columns = columns, .rows = rows };
}

fn spanCString(pointer: [*c]const u8) []const u8 {
    if (pointer == null) return "";
    const sentinel_pointer: [*:0]const u8 = @ptrCast(pointer);
    return std.mem.span(sentinel_pointer);
}
