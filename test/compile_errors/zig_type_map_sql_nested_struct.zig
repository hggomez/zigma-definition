//! expected: field 'desde' is a struct: nested structs have no SQL mapping yet
//! (the inner struct has no domain, so its composite type would have no name)
const map = @import("zig_type_map_sql");

const Punto = struct { x: i16, y: i16 };
const Recorrido = struct { desde: Punto, hasta: Punto };

comptime {
    _ = map.sqlTypeOf(Recorrido);
}
