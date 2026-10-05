const zigma = @import("zigma");
const contract = @import("fixtures/concrete_entities.zig");
// Framework debe comprobar el registro aunque se omita defineEntities.
comptime {
    _ = zigma.Framework(zigma.common_type_defs, .{ .items = .{ .definition = contract.item_def } });
}
