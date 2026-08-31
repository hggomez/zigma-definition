const zigma = @import("zigma");
const rest = @import("zigma_rest");

const type_defs = zigma.defineTypes(zigma.merge(.{
    zigma.common_type_defs,
    .{ .fecha = zigma.TypeDef{ .Type = []const u8 } },
}));
const fields = zigma.record(type_defs, .{ .when = .{ .type = "fecha" } });
const entity = zigma.defineEntity(.{ .pk = .{"when"}, .fields = fields });
const entities = zigma.defineEntities(.{ .events = entity });

comptime {
    _ = rest.Api(entities, rest.common_codecs);
}
