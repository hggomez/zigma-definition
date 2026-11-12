const supermarket = @import("supermercado");
comptime {
    _ = @as(@FieldType(supermarket.ProductoPrecio, "precio"), 12.34);
}
