//! Repositorio textual de prueba: resultados propios y contadores de escrituras/cleanup.
const std = @import("std");
const rest = @import("zigma_rest");

pub fn Repository(comptime names: []const []const u8) type {
    return struct {
        const Self = @This();
        columns: []const []const u8 = names,
        rows: []const []const ?[]const u8 = &.{},
        empty_write_result: bool = false,
        select_calls: usize = 0,
        insert_calls: usize = 0,
        update_calls: usize = 0,
        deinit_calls: usize = 0,
        expected_parameters: ?[]const rest.FieldValue = null,
        parameters_match: bool = false,

        pub const Result = struct {
            arena: std.heap.ArenaAllocator,
            columns: []const []const u8,
            rows: []const []const ?[]const u8,
            cleanup_count: *usize,

            pub fn deinit(self: *Result) void {
                self.arena.deinit();
                self.cleanup_count.* += 1;
            }
        };

        fn makeResult(self: *Self, allocator: std.mem.Allocator, source: []const []const ?[]const u8) rest.RepositoryError!Result {
            var arena = std.heap.ArenaAllocator.init(allocator);
            errdefer arena.deinit();
            const owned = arena.allocator();
            const columns = try owned.alloc([]const u8, self.columns.len);
            for (self.columns, 0..) |column, i| columns[i] = try owned.dupe(u8, column);
            const rows = try owned.alloc([]const ?[]const u8, source.len);
            for (source, 0..) |cells, i| {
                const row = try owned.alloc(?[]const u8, cells.len);
                for (cells, 0..) |cell, j| row[j] = if (cell) |bytes| try owned.dupe(u8, bytes) else null;
                rows[i] = row;
            }
            return .{ .arena = arena, .columns = columns, .rows = rows, .cleanup_count = &self.deinit_calls };
        }

        fn inspectParameters(self: *Self, values: []const rest.FieldValue) void {
            const expected = self.expected_parameters orelse return;
            self.parameters_match = expected.len == values.len;
            for (expected, 0..) |field, i| {
                if (i >= values.len) return;
                self.parameters_match = self.parameters_match and
                    std.mem.eql(u8, field.name, values[i].name) and optionalTextEqual(field.value, values[i].value);
            }
        }

        pub fn select(self: *Self, allocator: std.mem.Allocator, _: []const u8, _: []const rest.FieldValue) rest.RepositoryError!Result {
            self.select_calls += 1;
            return self.makeResult(allocator, self.rows);
        }

        pub fn insert(self: *Self, allocator: std.mem.Allocator, _: []const u8, values: []const rest.FieldValue) rest.RepositoryError!Result {
            self.insert_calls += 1;
            self.inspectParameters(values);
            if (self.empty_write_result) return self.makeResult(allocator, &.{});
            if (values.len != names.len) return error.DatabaseError;
            var row: [names.len]?[]const u8 = undefined;
            for (values, 0..) |value, i| row[i] = value.value;
            return self.makeResult(allocator, &.{&row});
        }

        pub fn update(self: *Self, allocator: std.mem.Allocator, _: []const u8, values: []const rest.FieldValue, _: []const rest.FieldValue) rest.RepositoryError!Result {
            self.update_calls += 1;
            self.inspectParameters(values);
            return self.makeResult(allocator, if (self.empty_write_result) &.{} else self.rows);
        }

        pub fn delete(self: *Self, allocator: std.mem.Allocator, _: []const u8, _: []const rest.FieldValue) rest.RepositoryError!Result {
            return self.makeResult(allocator, self.rows);
        }
    };
}

pub fn optionalTextEqual(left: ?[]const u8, right: ?[]const u8) bool {
    if (left) |text| return if (right) |other| std.mem.eql(u8, text, other) else false;
    return right == null;
}
