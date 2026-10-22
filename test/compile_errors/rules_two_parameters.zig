//! expected: rule 'checkBooking': must take exactly one parameter, an instance of its record
const zigma = @import("zigma");

const type_defs = zigma.common_type_defs;

const booking = zigma.record(type_defs, .{
    .room = .{ .type = "text" },
    .start = .{ .type = "integer" },
    .end = .{ .type = "integer" },
});

const Booking = zigma.RecordInstanceType(type_defs, booking);

fn checkBooking(b: Booking, other: Booking) error{Overlap}!void {
    if (b.start < other.end and other.start < b.end) return error.Overlap;
}

comptime {
    _ = zigma.defineRules(type_defs, .{ .checkBooking = .{ .record = booking, .rule = checkBooking } });
}
