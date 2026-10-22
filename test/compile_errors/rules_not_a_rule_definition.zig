//! expected: rule 'checkBooking': a rule definition must be a struct like .{ .record = ..., .rule = ... }
const zigma = @import("zigma");

const type_defs = zigma.common_type_defs;

const booking = zigma.record(type_defs, .{
    .room = .{ .type = "text" },
    .start = .{ .type = "integer" },
    .end = .{ .type = "integer" },
});

const Booking = zigma.RecordInstanceType(type_defs, booking);

comptime {
    _ = zigma.defineRules(type_defs, .{ .checkBooking = 42 });
}
