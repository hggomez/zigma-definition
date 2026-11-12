const supermarket = @import("supermercado");
comptime {
    _ = @as(@FieldType(supermarket.TicketProducto, "cantidad"), null);
}
