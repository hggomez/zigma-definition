//! Diagnóstico esperado: `source field 'inexistente' is not a field`.
//! Forma de mapa: la clave es el campo de origen.
const zigma = @import("zigma");
const aida = @import("aida");

comptime {
    _ = zigma.defineEntity(.{
        .pk = .{"materia"},
        .fks = .{ .x = .{ .entity = "materias", .fields = .{ .inexistente = "materia" } } },
        .fields = aida.materia,
    });
}
