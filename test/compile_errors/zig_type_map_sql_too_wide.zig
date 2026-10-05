//! expected: Zig type 'u64' does not fit in a Postgres BIGINT
//! (wider than i64: no Postgres integer holds its whole interval)
const map = @import("zig_type_map_sql");

comptime {
    _ = map.sqlTypeOf(u64);
}
