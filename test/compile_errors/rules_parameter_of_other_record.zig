//! expected: rule 'checkBooking': its parameter must be the instance type of its record
//! (the function takes a Room, the definition says booking)
const zigma = @import("zigma");

const type_defs = zigma.common_type_defs;

const booking = zigma.record(type_defs, .{
    .room = .{ .type = "text" },
    .start = .{ .type = "integer" },
    .end = .{ .type = "integer" },
});

const Booking = zigma.RecordInstanceType(type_defs, booking);

const room = zigma.record(type_defs, .{
    .room = .{ .type = "text" },
    .capacity = .{ .type = "integer" },
});

const Room = zigma.RecordInstanceType(type_defs, room);

fn checkBooking(r: Room) error{NoCapacity}!void {
    if (r.capacity <= 0) return error.NoCapacity;
}

comptime {
    _ = zigma.defineRules(type_defs, .{ .checkBooking = .{ .record = booking, .rule = checkBooking } });
}
