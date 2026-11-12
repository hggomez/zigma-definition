const zigma = @import("zigma");
const supermarket = @import("supermercado");
const definition = .{
    .fields = supermarket.producto_carrito_def.fields,
    .pk = supermarket.producto_carrito_def.pk,
    .fks = .{ .precio = .{ .entity = "productos_precios", .fields = .{ .id_producto = "id_producto" } } },
};
comptime {
    _ = zigma.defineEntities(zigma.merge(.{ supermarket.entity_defs, .{
        .productos_carritos = .{
            .Type = zigma.Entity(supermarket.type_defs, definition),
            .definition = definition,
        },
    } }));
}
