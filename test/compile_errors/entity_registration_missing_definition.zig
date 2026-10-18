const zigma = @import("zigma");
comptime {
    _ = zigma.defineEntities(.{ .items = .{ .Type = struct { id: i64 } } });
}
