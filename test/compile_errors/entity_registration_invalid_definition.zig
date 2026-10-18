const zigma = @import("zigma");
comptime {
    _ = zigma.defineEntities(.{ .items = .{ .Type = struct {}, .definition = 42 } });
}
