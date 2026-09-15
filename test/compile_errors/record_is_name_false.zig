//! Diagnóstico esperado: `is_name only admits true`.
//! En una Def solo se puede escribir `.is_name = true`; false es el default
//! y la normalización lo explicita, como `isName?: true` en TypeScript.
const zigma = @import("zigma");
const aida = @import("aida");

comptime {
    _ = zigma.record(aida.type_defs, .{
        .campo = .{ .type = "text", .is_name = false },
    });
}
