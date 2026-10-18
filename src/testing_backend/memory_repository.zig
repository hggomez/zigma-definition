//! In-memory repository with the same structural surface as `zigma_postgres_crud.Repository`.
//! Rows are stored as postgres-canonical text (`?[]const u8` cells) in entity field order.

const std = @import("std");
const rest = @import("zigma_rest");

pub fn MemoryRepository(comptime Model: type) type {
    const model_info = Model.info;
    const entity_names = @typeInfo(@TypeOf(model_info)).@"struct".field_names;

    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        tables: [entity_names.len]Table,

        const Table = struct {
            columns: []const []const u8,
            rows: std.ArrayList([]?[]const u8),
        };

        pub fn init(allocator: std.mem.Allocator) !Self {
            var tables: [entity_names.len]Table = undefined;
            inline for (entity_names, 0..) |entity_name, i| {
                const entity = @field(model_info, entity_name);
                const field_names = @typeInfo(@TypeOf(entity.fields)).@"struct".field_names;
                const columns = try allocator.alloc([]const u8, field_names.len);
                inline for (field_names, 0..) |field_name, j| {
                    columns[j] = try allocator.dupe(u8, field_name);
                }
                tables[i] = .{
                    .columns = columns,
                    .rows = .empty,
                };
            }
            return .{ .allocator = allocator, .tables = tables };
        }

        pub fn deinit(self: *Self) void {
            for (&self.tables) |*table| {
                for (table.rows.items) |row| freeRow(self.allocator, row);
                table.rows.deinit(self.allocator);
                for (table.columns) |column| self.allocator.free(column);
                self.allocator.free(table.columns);
            }
        }

        pub fn select(
            self: *Self,
            allocator: std.mem.Allocator,
            entity_name: []const u8,
            filters: []const rest.FieldValue,
        ) rest.RepositoryError!rest.QueryResult {
            inline for (entity_names, 0..) |name, i| {
                if (std.mem.eql(u8, entity_name, name))
                    return self.copyMatches(allocator, &self.tables[i], filters);
            }
            return error.DatabaseError;
        }

        pub fn insert(
            self: *Self,
            allocator: std.mem.Allocator,
            entity_name: []const u8,
            values: []const rest.FieldValue,
        ) rest.RepositoryError!rest.QueryResult {
            inline for (entity_names, 0..) |name, i| {
                if (std.mem.eql(u8, entity_name, name)) {
                    const entity = @field(model_info, name);
                    const table = &self.tables[i];
                    const row = try buildRow(self.allocator, entity, table.columns, values);
                    errdefer freeRow(self.allocator, row);
                    if (pkConflict(entity, table.columns, table.rows.items, row)) {
                        freeRow(self.allocator, row);
                        return error.Conflict;
                    }
                    try table.rows.append(self.allocator, row);
                    return copyRowResult(allocator, table.columns, row);
                }
            }
            return error.DatabaseError;
        }

        pub fn update(
            self: *Self,
            allocator: std.mem.Allocator,
            entity_name: []const u8,
            values: []const rest.FieldValue,
            filters: []const rest.FieldValue,
        ) rest.RepositoryError!rest.QueryResult {
            inline for (entity_names, 0..) |name, i| {
                if (std.mem.eql(u8, entity_name, name)) {
                    const table = &self.tables[i];
                    var updated: std.ArrayList([]const ?[]const u8) = .empty;
                    errdefer {
                        for (updated.items) |row| freeRow(allocator, @constCast(row));
                        updated.deinit(allocator);
                    }
                    for (table.rows.items) |row| {
                        if (!rowMatches(table.columns, row, filters)) continue;
                        try applyValues(self.allocator, table.columns, row, values);
                        try updated.append(allocator, try dupeRow(allocator, row));
                    }
                    return .{
                        .allocator = allocator,
                        .columns = try dupeColumns(allocator, table.columns),
                        .rows = try updated.toOwnedSlice(allocator),
                    };
                }
            }
            return error.DatabaseError;
        }

        pub fn delete(
            self: *Self,
            allocator: std.mem.Allocator,
            entity_name: []const u8,
            filters: []const rest.FieldValue,
        ) rest.RepositoryError!rest.QueryResult {
            inline for (entity_names, 0..) |name, i| {
                if (std.mem.eql(u8, entity_name, name)) {
                    const table = &self.tables[i];
                    var deleted: std.ArrayList([]const ?[]const u8) = .empty;
                    errdefer {
                        for (deleted.items) |row| freeRow(allocator, @constCast(row));
                        deleted.deinit(allocator);
                    }
                    var index: usize = 0;
                    while (index < table.rows.items.len) {
                        const row = table.rows.items[index];
                        if (!rowMatches(table.columns, row, filters)) {
                            index += 1;
                            continue;
                        }
                        try deleted.append(allocator, try dupeRow(allocator, row));
                        freeRow(self.allocator, row);
                        _ = table.rows.orderedRemove(index);
                    }
                    return .{
                        .allocator = allocator,
                        .columns = try dupeColumns(allocator, table.columns),
                        .rows = try deleted.toOwnedSlice(allocator),
                    };
                }
            }
            return error.DatabaseError;
        }

        fn copyMatches(
            self: *Self,
            allocator: std.mem.Allocator,
            table: *const Table,
            filters: []const rest.FieldValue,
        ) rest.RepositoryError!rest.QueryResult {
            _ = self;
            var matched: std.ArrayList([]const ?[]const u8) = .empty;
            errdefer {
                for (matched.items) |row| freeRow(allocator, @constCast(row));
                matched.deinit(allocator);
            }
            for (table.rows.items) |row| {
                if (!rowMatches(table.columns, row, filters)) continue;
                try matched.append(allocator, try dupeRow(allocator, row));
            }
            return .{
                .allocator = allocator,
                .columns = try dupeColumns(allocator, table.columns),
                .rows = try matched.toOwnedSlice(allocator),
            };
        }
    };
}

fn freeRow(allocator: std.mem.Allocator, row: []?[]const u8) void {
    for (row) |cell| if (cell) |bytes| allocator.free(bytes);
    allocator.free(row);
}

fn dupeColumns(allocator: std.mem.Allocator, columns: []const []const u8) rest.RepositoryError![]const []const u8 {
    const out = allocator.alloc([]const u8, columns.len) catch return error.OutOfMemory;
    errdefer allocator.free(out);
    for (columns, 0..) |column, i| {
        out[i] = allocator.dupe(u8, column) catch return error.OutOfMemory;
    }
    return out;
}

fn dupeRow(allocator: std.mem.Allocator, row: []const ?[]const u8) rest.RepositoryError![]?[]const u8 {
    const out = allocator.alloc(?[]const u8, row.len) catch return error.OutOfMemory;
    errdefer freeRow(allocator, out);
    for (row, 0..) |cell, i| {
        out[i] = if (cell) |bytes| allocator.dupe(u8, bytes) catch return error.OutOfMemory else null;
    }
    return out;
}

fn copyRowResult(
    allocator: std.mem.Allocator,
    columns: []const []const u8,
    row: []const ?[]const u8,
) rest.RepositoryError!rest.QueryResult {
    const rows = allocator.alloc([]const ?[]const u8, 1) catch return error.OutOfMemory;
    errdefer allocator.free(rows);
    rows[0] = try dupeRow(allocator, row);
    return .{
        .allocator = allocator,
        .columns = try dupeColumns(allocator, columns),
        .rows = rows,
    };
}

fn columnIndex(columns: []const []const u8, name: []const u8) ?usize {
    for (columns, 0..) |column, i| {
        if (std.mem.eql(u8, column, name)) return i;
    }
    return null;
}

fn rowMatches(
    columns: []const []const u8,
    row: []const ?[]const u8,
    filters: []const rest.FieldValue,
) bool {
    for (filters) |filter| {
        const index = columnIndex(columns, filter.name) orelse return false;
        const cell = row[index];
        const expected = filter.value orelse return false;
        if (cell == null) return false;
        if (!std.mem.eql(u8, cell.?, expected)) return false;
    }
    return true;
}

fn applyValues(
    allocator: std.mem.Allocator,
    columns: []const []const u8,
    row: []?[]const u8,
    values: []const rest.FieldValue,
) rest.RepositoryError!void {
    for (values) |value| {
        const index = columnIndex(columns, value.name) orelse return error.DatabaseError;
        if (row[index]) |old| allocator.free(old);
        row[index] = if (value.value) |bytes|
            allocator.dupe(u8, bytes) catch return error.OutOfMemory
        else
            null;
    }
}

fn buildRow(
    allocator: std.mem.Allocator,
    comptime entity: anytype,
    columns: []const []const u8,
    values: []const rest.FieldValue,
) rest.RepositoryError![]?[]const u8 {
    const field_names = @typeInfo(@TypeOf(entity.fields)).@"struct".field_names;
    if (columns.len != field_names.len) return error.DatabaseError;
    const row = allocator.alloc(?[]const u8, field_names.len) catch return error.OutOfMemory;
    errdefer freeRow(allocator, row);
    @memset(row, null);
    inline for (field_names, 0..) |field_name, i| {
        const found = findValue(values, field_name) orelse return error.DatabaseError;
        row[i] = if (found.value) |bytes|
            allocator.dupe(u8, bytes) catch return error.OutOfMemory
        else
            null;
    }
    return row;
}

fn findValue(values: []const rest.FieldValue, name: []const u8) ?rest.FieldValue {
    for (values) |value| {
        if (std.mem.eql(u8, value.name, name)) return value;
    }
    return null;
}

fn pkConflict(
    comptime entity: anytype,
    columns: []const []const u8,
    rows: []const []?[]const u8,
    row: []const ?[]const u8,
) bool {
    for (rows) |existing| {
        var same = true;
        inline for (entity.pk) |pk_name| {
            const index = columnIndex(columns, pk_name) orelse return true;
            const a = existing[index];
            const b = row[index];
            if (a == null or b == null or !std.mem.eql(u8, a.?, b.?)) {
                same = false;
                break;
            }
        }
        if (same) return true;
    }
    return false;
}
