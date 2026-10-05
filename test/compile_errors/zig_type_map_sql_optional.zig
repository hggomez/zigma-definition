//! expected: Zig type '?u8' has no SQL mapping
//! (nullability lives in the zigma field, `nullable`, not in the Zig type)
const map = @import("zig_type_map_sql");

comptime {
    _ = map.sqlTypeOf(?u8);
}
