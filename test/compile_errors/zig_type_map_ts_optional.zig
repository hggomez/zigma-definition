//! expected: Zig type '?u8' has no TS mapping
//! (nullability lives in the zigma field, `nullable`, not in the Zig type)
const map = @import("zig_type_map_ts");

comptime {
    _ = map.tsTypeOf(?u8);
}
