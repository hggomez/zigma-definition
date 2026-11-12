const supermarket = @import("supermercado");
comptime {
    _ = @as(@FieldType(supermarket.ProductoCarrito, "id_precio"), null);
}
