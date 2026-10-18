//! Diagnóstico esperado: `type 'text': must be a TypeDef`.
//! Comprobación en la declaración: se informa el error donde se define
//! la colección, no donde se usa por primera vez.
const zigma = @import("zigma");

comptime {
    _ = zigma.defineTypes(.{ .text = 42 });
}
