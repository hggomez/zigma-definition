//! expected: rule 'checkBooking': must be a validation, returning error{...}!void
//! (an error union, but with a payload other than void)
const zigma = @import("zigma");

const type_defs = zigma.common_type_defs;

const booking = zigma.record(type_defs, .{
    .room = .{ .type = "text" },
    .start = .{ .type = "integer" },
    .end = .{ .type = "integer" },
});

const Booking = zigma.RecordInstanceType(type_defs, booking);

fn checkBooking(b: Booking) error{EndBeforeStart}!i64 {
    if (b.end < b.start) return error.EndBeforeStart;
    return b.end - b.start;
}

comptime {
    _ = zigma.defineRules(type_defs, .{ .checkBooking = .{ .record = booking, .rule = checkBooking } });
}
