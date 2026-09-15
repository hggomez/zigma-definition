//! Diagnóstico esperado: `unknown type 'inexistente'`.
const zigma = @import("zigma");
const aida = @import("aida");

comptime {
    _ = zigma.record(aida.type_defs, .{
        .campo = .{ .type = "inexistente" },
    });
}
