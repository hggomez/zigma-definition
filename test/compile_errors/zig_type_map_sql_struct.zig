//! expected: Zig type '<module>.Punto' has no SQL mapping (matched by its end)
//! (structs are not mapped yet: the composite type comes next)
const map = @import("zig_type_map_sql");

const Punto = struct { x: i16, y: i16 };

comptime {
    _ = map.sqlTypeOf(Punto);
}
