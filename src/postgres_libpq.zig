//! Minimal blocking libpq adapter for trusted PostgreSQL DDL.
//!
//! This is intentionally not a general database client: there are no query
//! parameters, result rows, pooling, or CRUD helpers. Its public methods form
//! the structural contract consumed by `zigma_postgres_executor`.

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

    pub fn init(allocator: std.mem.Allocator) Connection {
        return .{ .allocator = allocator };
    }

    pub fn connect(self: *Connection, conninfo: []const u8) Error!void {
        if (self.handle != null) return error.AlreadyConnected;
        if (std.mem.indexOfScalar(u8, conninfo, 0) != null)
            return error.ConnectionStringContainsNul;

        self.clearLastError();
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

        self.clearLastError();
        const terminated = self.allocator.dupeSentinel(u8, sql, 0) catch
            return error.OutOfMemory;
        defer self.allocator.free(terminated);
        try self.execTerminated(handle, terminated, .replace);
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
};

fn spanCString(pointer: [*c]const u8) []const u8 {
    if (pointer == null) return "";
    const sentinel_pointer: [*:0]const u8 = @ptrCast(pointer);
    return std.mem.span(sentinel_pointer);
}
