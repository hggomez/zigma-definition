//! Diagnóstico esperado: `do not match the complete pk nor any uk`.
//! Se rechaza una FK que referencia solo parte de una PK compuesta
//! y ninguna UK: falta 'hora'.
const zigma = @import("zigma");
const aida = @import("aida");

comptime {
    const franjas = zigma.defineEntity(.{
        .pk = .{ "dia", "hora" },
        .fields = zigma.record(aida.type_defs, .{
            .dia = .{ .type = "text" },
            .hora = .{ .type = "integer" },
        }),
    });
    const eventos = zigma.defineEntity(.{
        .pk = .{"evento"},
        .fks = .{ .franja = .{ .entity = "franjas", .fields = .{ .dia = "dia" } } },
        .fields = zigma.record(aida.type_defs, .{
            .evento = .{ .type = "text" },
            .dia = .{ .type = "text" },
        }),
    });
    _ = zigma.defineEntities(.{ .franjas = franjas, .eventos = eventos });
}
