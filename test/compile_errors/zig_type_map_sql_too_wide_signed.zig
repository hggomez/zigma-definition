//! expected: Zig type 'i65' does not fit in a Postgres BIGINT
const map = @import("zig_type_map_sql");

comptime {
    _ = map.sqlTypeOf(i65);
}
