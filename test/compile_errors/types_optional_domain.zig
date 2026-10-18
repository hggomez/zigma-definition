const zigma = @import("zigma");

comptime {
    _ = zigma.defineTypes(.{
        .optional_integer = zigma.TypeDef{ .Type = ?i64 },
    });
}
