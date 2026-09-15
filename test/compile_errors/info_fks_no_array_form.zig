//! Diagnóstico esperado: `expected type`.
//! Después de normalizar desaparece la forma de array: fields siempre es
//! el mapa origen→destino y no se puede usar como una lista.
const zigma = @import("zigma");
const aida = @import("aida");

comptime {
    const mesas_info = zigma.completeEntity(aida.mesas);
    const as_list: []const [:0]const u8 = mesas_info.fks.cursos.fields;
    _ = as_list;
}
