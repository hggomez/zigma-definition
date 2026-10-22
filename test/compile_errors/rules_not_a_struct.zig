//! expected: a rule collection must be a struct of rule definitions
const zigma = @import("zigma");

const type_defs = zigma.common_type_defs;

const booking = zigma.record(type_defs, .{
    .room = .{ .type = "text" },
    .start = .{ .type = "integer" },
    .end = .{ .type = "integer" },
});

const Booking = zigma.RecordInstanceType(type_defs, booking);

comptime {
    _ = zigma.defineRules(type_defs, 42);
}
