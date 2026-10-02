//! expected: type 'text' is not a struct-backed domain
const zigma = @import("zigma");
const sql = @import("sql_generator");

comptime {
    _ = sql.createTypeSql(zigma.common_type_defs, "text");
}
