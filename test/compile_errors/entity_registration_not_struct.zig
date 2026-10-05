const zigma = @import("zigma");
comptime {
    _ = zigma.defineEntities(.{ .items = 42 });
}
