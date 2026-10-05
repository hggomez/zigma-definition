const zigma = @import("zigma");

comptime {
    // El tipo registrado es válido; el dominio opcional debe rechazarse dentro
    // de Framework, sin depender de una llamada previa a defineTypes o Entity.
    const definition = .{
        .pk = .{"id"},
        .fields = .{ .id = .{ .type = "optional_integer" } },
    };
    const Item = zigma.Entity(.{ .optional_integer = .{ .Type = i64 } }, definition);
    _ = zigma.Framework(
        .{ .optional_integer = .{ .Type = ?i64 } },
        .{ .things = .{ .Type = Item, .definition = definition } },
    );
}
