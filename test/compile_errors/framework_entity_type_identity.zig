const zigma = @import("zigma");
const contract = @import("fixtures/concrete_entities.zig");
// Coincidir estructuralmente no reemplaza la identidad del tipo generado.
const Manual = struct { id: i64, label: []const u8, note: ?[]const u8 };
comptime {
    const registrations = zigma.defineEntities(.{ .items = .{ .Type = Manual, .definition = contract.item_def } });
    _ = zigma.Framework(zigma.common_type_defs, registrations);
}
