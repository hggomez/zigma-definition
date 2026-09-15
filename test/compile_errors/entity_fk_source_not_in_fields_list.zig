//! Diagnóstico esperado: `source field 'inexistente' is not a field`.
//! Forma de lista: origen y destino comparten el nombre.
const zigma = @import("zigma");
const aida = @import("aida");

comptime {
    _ = zigma.defineEntity(.{
        .pk = .{"materia"},
        .fks = .{ .x = .{ .entity = "materias", .fields = .{"inexistente"} } },
        .fields = aida.materia,
    });
}
