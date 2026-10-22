//! expected: type 'fecha' is not in type_defs
//! (the entity is defined with aida's types, the generator is given only the
//! common ones)
const zigma = @import("zigma");
const aida = @import("aida");
const sql = @import("sql_generator");

const clases_info = zigma.completeEntity(aida.clases);

comptime {
    _ = sql.createTableSql(zigma.common_type_defs, "clases", clases_info);
}
