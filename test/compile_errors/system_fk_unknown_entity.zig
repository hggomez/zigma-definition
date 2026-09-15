//! Diagnóstico esperado: `unknown target entity 'inexistentes'`.
//! Se rechaza una FK a una entidad que no pertenece al sistema.
const zigma = @import("zigma");
const aida = @import("aida");

comptime {
    const huerfanos = zigma.defineEntity(.{
        .pk = .{"x"},
        .fks = .{ .rota = .{ .entity = "inexistentes", .fields = .{ .x = "algo" } } },
        .fields = zigma.record(aida.type_defs, .{ .x = .{ .type = "text" } }),
    });
    _ = zigma.defineEntities(.{ .huerfanos = huerfanos });
}
