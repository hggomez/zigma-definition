//! Helpers internos compartidos para reconocer y comparar nombres del contrato.
//! No dependen de records, entidades ni del modelo.

const std = @import("std");

pub fn eql(comptime a: []const u8, comptime b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn isStringType(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => return p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| return a.child == u8,
                else => return false,
            },
            else => return false,
        },
        else => return false,
    }
}

pub fn containsName(comptime names: anytype, comptime name: []const u8) bool {
    for (names) |n| {
        if (eql(n, name)) return true;
    }
    return false;
}
