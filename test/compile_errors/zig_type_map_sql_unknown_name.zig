//! expected: type 'inexistente' has no SQL mapping
//! Neither a Zig type name in the framework's table nor a named domain.
const zigma = @import("zigma");
const map_sql = @import("zig_type_map_sql");

comptime {
    _ = map_sql.sqlType(zigma.common_type_defs, "inexistente");
}
