const zigma = @import("zigma");
pub const Context = struct { minimum: i64 };
pub const OtherContext = struct { maximum: i64 };
const definition = .{ .pk = .{"id"}, .fields = zigma.record(zigma.common_type_defs, .{
    .id = .{ .type = "integer" },
}) };
pub const Row = zigma.Entity(zigma.common_type_defs, definition);
pub const Model = zigma.Framework(zigma.common_type_defs, .{
    .firsts = .{ .Type = Row, .definition = definition },
    .seconds = .{ .Type = Row, .definition = definition },
});
