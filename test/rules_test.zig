//! The rules of a system: domain validations written once in Zig and
//! declared with `zigma.defineRules`, so that generators can find them. The
//! negative cases are the expected compile errors in
//! test/compile_errors/rules_*.zig, driven by build.zig.
//!
//! The system here is a small one of its own, built only from zigma (no
//! aida): rooms and their bookings.

const std = @import("std");
const zigma = @import("zigma");

const expect = std.testing.expect;
const expectError = std.testing.expectError;

const type_defs = zigma.common_type_defs;

const room = zigma.record(type_defs, .{
    .room = .{ .type = "text" },
    .capacity = .{ .type = "integer" },
});

const booking = zigma.record(type_defs, .{
    .room = .{ .type = "text" },
    .start = .{ .type = "integer" },
    .end = .{ .type = "integer" },
});

const Room = zigma.RecordInstanceType(type_defs, room);
const Booking = zigma.RecordInstanceType(type_defs, booking);

fn checkRoom(r: Room) error{NoCapacity}!void {
    if (r.capacity <= 0) return error.NoCapacity;
}

fn checkBooking(b: Booking) error{ EndBeforeStart, Empty }!void {
    if (b.end < b.start) return error.EndBeforeStart;
    if (b.end == b.start) return error.Empty;
}

const rule_defs = zigma.defineRules(type_defs, .{
    .checkRoom = .{ .record = room, .rule = checkRoom },
    .checkBooking = .{ .record = booking, .rule = checkBooking },
});

test "defineRules returns the rules unchanged" {
    comptime {
        std.debug.assert(@typeInfo(@TypeOf(rule_defs)).@"struct".field_names.len == 2);
        // the same functions: compared as function pointers (`&` of the field
        // would be the address of the field, not of the function)
        std.debug.assert(@as(*const @TypeOf(checkRoom), rule_defs.checkRoom.rule) == &checkRoom);
        std.debug.assert(@as(*const @TypeOf(checkBooking), rule_defs.checkBooking.rule) == &checkBooking);
        std.debug.assert(@TypeOf(rule_defs.checkRoom.record) == @TypeOf(room));
        std.debug.assert(@TypeOf(rule_defs.checkBooking.record) == @TypeOf(booking));
    }
}

test "a rule runs through its definition: passes or returns its domain error" {
    try rule_defs.checkRoom.rule(.{ .room = "A", .capacity = 10 });
    try expectError(error.NoCapacity, rule_defs.checkRoom.rule(.{ .room = "A", .capacity = 0 }));

    try rule_defs.checkBooking.rule(.{ .room = "A", .start = 9, .end = 11 });
    try expectError(error.EndBeforeStart, rule_defs.checkBooking.rule(.{ .room = "A", .start = 11, .end = 9 }));
    try expectError(error.Empty, rule_defs.checkBooking.rule(.{ .room = "A", .start = 9, .end = 9 }));
}

test "a system without rules declares an empty collection" {
    const none = zigma.defineRules(type_defs, .{});
    comptime std.debug.assert(@typeInfo(@TypeOf(none)).@"struct".field_names.len == 0);
}
