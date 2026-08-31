//! Parameterized PostgreSQL CRUD derived from Zigma entities.
//!
//! Only comptime-known table and column identifiers enter SQL. Every request
//! value is passed separately through `$n` parameters.

const std = @import("std");
const zigma = @import("zigma");
const rest = @import("zigma_rest");

fn baseType(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.child,
        else => T,
    };
}

fn queryResultType(comptime ConnectionType: type) type {
    const function_type = @TypeOf(@field(baseType(ConnectionType), "queryParams"));
    const return_type = @typeInfo(function_type).@"fn".return_type orelse
        @compileError("queryParams must have a return type");
    const return_info = @typeInfo(return_type);
    if (return_info != .error_union)
        @compileError("queryParams must return an error union containing an owned tabular result");
    return return_info.error_union.payload;
}

fn appendIdentifier(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    identifier: []const u8,
) std.mem.Allocator.Error!void {
    try output.append(allocator, '"');
    for (identifier) |byte| {
        try output.append(allocator, byte);
        if (byte == '"') try output.append(allocator, '"');
    }
    try output.append(allocator, '"');
}

fn appendParameter(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    number: usize,
) std.mem.Allocator.Error!void {
    var buffer: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "${d}", .{number}) catch unreachable;
    try output.appendSlice(allocator, text);
}

fn findValue(values: []const rest.FieldValue, name: []const u8) ?rest.FieldValue {
    for (values) |value|
        if (std.mem.eql(u8, value.name, name)) return value;
    return null;
}

fn hasUnknownOrDuplicate(comptime entity: anytype, values: []const rest.FieldValue) bool {
    for (values, 0..) |value, index| {
        var known = false;
        inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
            if (std.mem.eql(u8, value.name, field_name)) known = true;
        }
        if (!known) return true;
        for (values[index + 1 ..]) |later|
            if (std.mem.eql(u8, value.name, later.name)) return true;
    }
    return false;
}

fn appendWhere(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    parameters: *std.ArrayList(?[]const u8),
    comptime entity: anytype,
    filters: []const rest.FieldValue,
) std.mem.Allocator.Error!void {
    if (filters.len == 0) return;
    try output.appendSlice(allocator, " WHERE ");
    var emitted: usize = 0;
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
        if (findValue(filters, field_name)) |filter| {
            if (emitted != 0) try output.appendSlice(allocator, " AND ");
            try appendIdentifier(allocator, output, field_name);
            try output.appendSlice(allocator, " = ");
            try parameters.append(allocator, filter.value);
            try appendParameter(allocator, output, parameters.items.len);
            emitted += 1;
        }
    }
}

fn mapDatabaseError(connection: anytype, err: anyerror) rest.RepositoryError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotConnected, error.ConnectionFailed => error.Unavailable,
        error.PostgresError => blk: {
            if (connection.lastSqlState()) |state| {
                if (state.len >= 2) {
                    if (state[0] == '2' and state[1] == '3')
                        break :blk error.Conflict;
                    if (state[0] == '0' and state[1] == '8')
                        break :blk error.Unavailable;
                }
            }
            break :blk error.DatabaseError;
        },
        else => error.DatabaseError,
    };
}

/// Creates a repository factory for one complete Zigma entity system.
///
/// The connection remains structural: any pointer exposing `queryParams` and
/// `lastSqlState` can be bound, which keeps unit tests and a future pg.zig
/// adapter independent from libpq.
pub fn Repository(comptime entity_defs: anytype) type {
    const validated = zigma.defineEntities(entity_defs);

    return struct {
        pub fn init(connection: anytype) Bound(@TypeOf(connection)) {
            return .{ .connection = connection };
        }

        pub fn Bound(comptime ConnectionType: type) type {
            const Result = queryResultType(ConnectionType);
            return struct {
                const Self = @This();
                connection: ConnectionType,

                pub fn select(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    entity_name: []const u8,
                    filters: []const rest.FieldValue,
                ) rest.RepositoryError!Result {
                    inline for (@typeInfo(@TypeOf(validated)).@"struct".field_names) |name| {
                        if (std.mem.eql(u8, entity_name, name))
                            return self.selectEntity(allocator, name, filters);
                    }
                    return error.DatabaseError;
                }

                fn selectEntity(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    comptime entity_name: []const u8,
                    filters: []const rest.FieldValue,
                ) rest.RepositoryError!Result {
                    const entity = @field(validated, entity_name);
                    if (hasUnknownOrDuplicate(entity, filters)) return error.DatabaseError;
                    var sql: std.ArrayList(u8) = .empty;
                    defer sql.deinit(allocator);
                    var parameters: std.ArrayList(?[]const u8) = .empty;
                    defer parameters.deinit(allocator);
                    sql.appendSlice(allocator, "SELECT * FROM ") catch return error.OutOfMemory;
                    appendIdentifier(allocator, &sql, entity_name) catch return error.OutOfMemory;
                    appendWhere(allocator, &sql, &parameters, entity, filters) catch return error.OutOfMemory;
                    return self.connection.queryParams(allocator, sql.items, parameters.items) catch |err|
                        return mapDatabaseError(self.connection, err);
                }

                pub fn insert(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    entity_name: []const u8,
                    values: []const rest.FieldValue,
                ) rest.RepositoryError!Result {
                    inline for (@typeInfo(@TypeOf(validated)).@"struct".field_names) |name| {
                        if (std.mem.eql(u8, entity_name, name))
                            return self.insertEntity(allocator, name, values);
                    }
                    return error.DatabaseError;
                }

                fn insertEntity(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    comptime entity_name: []const u8,
                    values: []const rest.FieldValue,
                ) rest.RepositoryError!Result {
                    const entity = @field(validated, entity_name);
                    if (values.len == 0 or hasUnknownOrDuplicate(entity, values)) return error.DatabaseError;
                    var sql: std.ArrayList(u8) = .empty;
                    defer sql.deinit(allocator);
                    var parameters: std.ArrayList(?[]const u8) = .empty;
                    defer parameters.deinit(allocator);
                    sql.appendSlice(allocator, "INSERT INTO ") catch return error.OutOfMemory;
                    appendIdentifier(allocator, &sql, entity_name) catch return error.OutOfMemory;
                    sql.appendSlice(allocator, " (") catch return error.OutOfMemory;
                    var emitted: usize = 0;
                    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
                        if (findValue(values, field_name)) |value| {
                            if (emitted != 0) sql.appendSlice(allocator, ", ") catch return error.OutOfMemory;
                            appendIdentifier(allocator, &sql, field_name) catch return error.OutOfMemory;
                            parameters.append(allocator, value.value) catch return error.OutOfMemory;
                            emitted += 1;
                        }
                    }
                    sql.appendSlice(allocator, ") VALUES (") catch return error.OutOfMemory;
                    for (parameters.items, 0..) |_, index| {
                        if (index != 0) sql.appendSlice(allocator, ", ") catch return error.OutOfMemory;
                        appendParameter(allocator, &sql, index + 1) catch return error.OutOfMemory;
                    }
                    sql.appendSlice(allocator, ") RETURNING *") catch return error.OutOfMemory;
                    return self.connection.queryParams(allocator, sql.items, parameters.items) catch |err|
                        return mapDatabaseError(self.connection, err);
                }

                pub fn update(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    entity_name: []const u8,
                    values: []const rest.FieldValue,
                    filters: []const rest.FieldValue,
                ) rest.RepositoryError!Result {
                    inline for (@typeInfo(@TypeOf(validated)).@"struct".field_names) |name| {
                        if (std.mem.eql(u8, entity_name, name))
                            return self.updateEntity(allocator, name, values, filters);
                    }
                    return error.DatabaseError;
                }

                fn updateEntity(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    comptime entity_name: []const u8,
                    values: []const rest.FieldValue,
                    filters: []const rest.FieldValue,
                ) rest.RepositoryError!Result {
                    const entity = @field(validated, entity_name);
                    if (values.len == 0 or filters.len == 0 or hasUnknownOrDuplicate(entity, values) or hasUnknownOrDuplicate(entity, filters))
                        return error.DatabaseError;
                    var sql: std.ArrayList(u8) = .empty;
                    defer sql.deinit(allocator);
                    var parameters: std.ArrayList(?[]const u8) = .empty;
                    defer parameters.deinit(allocator);
                    sql.appendSlice(allocator, "UPDATE ") catch return error.OutOfMemory;
                    appendIdentifier(allocator, &sql, entity_name) catch return error.OutOfMemory;
                    sql.appendSlice(allocator, " SET ") catch return error.OutOfMemory;
                    var emitted: usize = 0;
                    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
                        if (findValue(values, field_name)) |value| {
                            if (emitted != 0) sql.appendSlice(allocator, ", ") catch return error.OutOfMemory;
                            appendIdentifier(allocator, &sql, field_name) catch return error.OutOfMemory;
                            sql.appendSlice(allocator, " = ") catch return error.OutOfMemory;
                            parameters.append(allocator, value.value) catch return error.OutOfMemory;
                            appendParameter(allocator, &sql, parameters.items.len) catch return error.OutOfMemory;
                            emitted += 1;
                        }
                    }
                    appendWhere(allocator, &sql, &parameters, entity, filters) catch return error.OutOfMemory;
                    sql.appendSlice(allocator, " RETURNING *") catch return error.OutOfMemory;
                    return self.connection.queryParams(allocator, sql.items, parameters.items) catch |err|
                        return mapDatabaseError(self.connection, err);
                }

                pub fn delete(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    entity_name: []const u8,
                    filters: []const rest.FieldValue,
                ) rest.RepositoryError!Result {
                    inline for (@typeInfo(@TypeOf(validated)).@"struct".field_names) |name| {
                        if (std.mem.eql(u8, entity_name, name))
                            return self.deleteEntity(allocator, name, filters);
                    }
                    return error.DatabaseError;
                }

                fn deleteEntity(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    comptime entity_name: []const u8,
                    filters: []const rest.FieldValue,
                ) rest.RepositoryError!Result {
                    const entity = @field(validated, entity_name);
                    if (filters.len == 0 or hasUnknownOrDuplicate(entity, filters)) return error.DatabaseError;
                    var sql: std.ArrayList(u8) = .empty;
                    defer sql.deinit(allocator);
                    var parameters: std.ArrayList(?[]const u8) = .empty;
                    defer parameters.deinit(allocator);
                    sql.appendSlice(allocator, "DELETE FROM ") catch return error.OutOfMemory;
                    appendIdentifier(allocator, &sql, entity_name) catch return error.OutOfMemory;
                    appendWhere(allocator, &sql, &parameters, entity, filters) catch return error.OutOfMemory;
                    sql.appendSlice(allocator, " RETURNING *") catch return error.OutOfMemory;
                    return self.connection.queryParams(allocator, sql.items, parameters.items) catch |err|
                        return mapDatabaseError(self.connection, err);
                }
            };
        }
    };
}
