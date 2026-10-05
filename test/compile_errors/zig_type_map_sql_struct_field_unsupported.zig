//! expected: Zig type 'f64' has no SQL mapping
//! (a struct field is mapped recursively, so its error surfaces too)
const map = @import("zig_type_map_sql");

const Medida = struct { nombre: []const u8, valor: f64 };

comptime {
    _ = map.sqlTypeOf(Medida);
}
