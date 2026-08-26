//! expected: type 'text' has no SQL mapping
const zigma = @import("zigma");
const sql = @import("sql_generator");

const entidad = zigma.defineEntity(.{
    .pk = .{"campo"},
    .fields = zigma.record(zigma.common_type_defs, .{
        .campo = .{ .type = "text" },
    }),
});
const entidad_info = zigma.completeEntity(entidad);

comptime {
    _ = sql.createTableSql(.{ .integer = "INTEGER" }, "entidad", entidad_info);
}
