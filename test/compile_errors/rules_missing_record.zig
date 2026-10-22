//! expected: rule 'checkBooking': missing 'record'
const zigma = @import("zigma");

const type_defs = zigma.common_type_defs;

const booking = zigma.record(type_defs, .{
    .room = .{ .type = "text" },
    .start = .{ .type = "integer" },
    .end = .{ .type = "integer" },
});

const Booking = zigma.RecordInstanceType(type_defs, booking);

fn checkBooking(b: Booking) error{EndBeforeStart}!void {
    if (b.end < b.start) return error.EndBeforeStart;
}

comptime {
    _ = zigma.defineRules(type_defs, .{ .checkBooking = .{ .rule = checkBooking } });
}
