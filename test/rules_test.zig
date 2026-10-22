//! The rules of a system: domain validations written once in Zig and
//! declared with `zigma.defineRules`, so that generators can find them. The
//! negative cases are the expected compile errors in
//! test/compile_errors/rules_*.zig, driven by build.zig.
//!
//! The system here is a small one of its own, built only from zigma (no
//! aida): rooms and their bookings, test/test_system.zig.

const std = @import("std");
const zigma = @import("zigma");
const test_system = @import("test_system");

const expectError = std.testing.expectError;

const type_defs = test_system.type_defs;
const room = test_system.room;
const booking = test_system.booking;
const checkRoom = test_system.checkRoom;
const checkBooking = test_system.checkBooking;
const rule_defs = test_system.rule_defs;

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
