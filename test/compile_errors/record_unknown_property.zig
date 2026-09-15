//! Diagnóstico esperado: `unknown property 'colour'`.
const zigma = @import("zigma");
const aida = @import("aida");

comptime {
    _ = zigma.record(aida.type_defs, .{
        .campo = .{ .type = "text", .colour = "red" },
    });
}
