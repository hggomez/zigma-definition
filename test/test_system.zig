//! A small system of its own (rooms and bookings, no aida) with rules, for
//! the tests of the rules WASM module: build.zig gives it to that module as
//! its "system" (a system module exposes `type_defs` and `rule_defs`).

const zigma = @import("zigma");

pub const type_defs = zigma.common_type_defs;

pub const room = zigma.record(type_defs, .{
    .room = .{ .type = "text" },
    .capacity = .{ .type = "integer" },
});

pub const booking = zigma.record(type_defs, .{
    .room = .{ .type = "text" },
    .start = .{ .type = "integer" },
    .end = .{ .type = "integer" },
});

pub const Room = zigma.RecordInstanceType(type_defs, room);
pub const Booking = zigma.RecordInstanceType(type_defs, booking);

pub fn checkRoom(r: Room) error{NoCapacity}!void {
    if (r.capacity <= 0) return error.NoCapacity;
}

pub fn checkBooking(b: Booking) error{ EndBeforeStart, Empty }!void {
    if (b.end < b.start) return error.EndBeforeStart;
    if (b.end == b.start) return error.Empty;
}

pub const rule_defs = zigma.defineRules(type_defs, .{
    .checkRoom = .{ .record = room, .rule = checkRoom },
    .checkBooking = .{ .record = booking, .rule = checkBooking },
});
