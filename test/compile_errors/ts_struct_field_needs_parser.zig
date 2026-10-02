//! expected: field 'grande' of struct domain 'medida': i64 inside a struct is not supported yet (to_jsonb would lose precision)
//! A struct field whose Zig type needs a pg parser on read (ts_parser_defs)
//! cannot travel inside the jsonb that decodes a struct column.
const zigma = @import("zigma");
const ts = @import("ts_backend_generator");

const Medida = struct { grande: i64, chica: i16 };

const type_defs = zigma.defineTypes(zigma.merge(.{ zigma.common_type_defs, .{
    .medida = zigma.TypeDef{ .Type = Medida },
} }));

const objeto = zigma.defineEntity(.{
    .pk = .{"objeto"},
    .fields = zigma.record(type_defs, .{
        .objeto = .{ .type = "text" },
        .medida = .{ .type = "medida" },
    }),
});

comptime {
    _ = ts.selectByPkFn(type_defs, "objeto", zigma.completeEntity(objeto));
}
