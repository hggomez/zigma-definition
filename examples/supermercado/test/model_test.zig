const std = @import("std");
const zigma = @import("zigma");
const supermarket = @import("supermercado");
const system = @import("system");
const Model = supermarket.Model;
const expect = std.testing.expect;

fn expectNames(actual: anytype, comptime expected: []const []const u8) !void {
    try expect(actual.len == expected.len);
    inline for (expected, 0..) |name, i| try std.testing.expectEqualStrings(name, actual[i]);
}

test "el consumidor registra exactamente las ocho entidades del MER y expone sus tipos de datos concretos" {
    try expect(@typeInfo(@TypeOf(Model.info)).@"struct".field_names.len == 8);
    inline for (.{
        .{ "productos", supermarket.Producto },
        .{ "productos_precios", supermarket.ProductoPrecio },
        .{ "clientes", supermarket.Cliente },
        .{ "carritos", supermarket.Carrito },
        .{ "productos_carritos", supermarket.ProductoCarrito },
        .{ "descuentos_cantidad", supermarket.DescuentoCantidad },
        .{ "tickets", supermarket.Ticket },
        .{ "tickets_productos", supermarket.TicketProducto },
    }) |entry| {
        try expect(Model.Row(entry[0]) == entry[1]);
        try expect(@field(supermarket.entity_defs, entry[0]).Type == entry[1]);
    }
    const ConsumerModel = zigma.Framework(system.type_defs, system.entity_defs);
    try expect(ConsumerModel.Row("productos_carritos") == supermarket.ProductoCarrito);
}

test "cada detalle tiene un renglón por producto y ambas partes de su clave primaria son obligatorias" {
    try expectNames(Model.info.productos_carritos.pk, &.{ "id_carrito", "id_producto" });
    try expectNames(Model.info.tickets_productos.pk, &.{ "id_ticket", "id_producto" });
    inline for (.{ "productos_carritos", "tickets_productos" }) |entity| {
        const info = @field(Model.info, entity);
        inline for (info.pk) |field| try expect(!@field(info.fields, field).nullable);
    }
}

test "cada entidad expone exactamente los atributos acordados en el MER" {
    inline for (.{
        .{ "productos", .{ "id", "nombre", "descripcion" } },
        .{ "productos_precios", .{ "id", "id_producto", "vigencia_desde", "precio" } },
        .{ "clientes", .{ "id", "nombre" } },
        .{ "carritos", .{ "id", "fecha_inicio", "estado", "id_cliente" } },
        .{ "productos_carritos", .{ "id_carrito", "id_producto", "cantidad", "id_precio", "id_descuento" } },
        .{ "descuentos_cantidad", .{ "id", "id_producto", "vigencia_desde", "cantidad_llevar", "descuento_porcentaje", "activo" } },
        .{ "tickets", .{ "id", "id_carrito", "fecha_emision", "total", "id_cliente" } },
        .{ "tickets_productos", .{ "id_ticket", "id_producto", "cantidad", "precio_unitario", "importe_descuento" } },
    }) |entry| {
        const Row = Model.Row(entry[0]);
        try expect(@typeInfo(Row).@"struct".field_names.len == entry[1].len);
        inline for (entry[1]) |field| try expect(@hasField(Row, field));
    }
}

test "solo las referencias al cliente y la promoción del carrito admiten null" {
    inline for (@typeInfo(@TypeOf(Model.info)).@"struct".field_names) |entity| {
        const fields = @field(Model.info, entity).fields;
        inline for (@typeInfo(@TypeOf(fields)).@"struct".field_names) |field| {
            const optional = ((std.mem.eql(u8, entity, "carritos") or std.mem.eql(u8, entity, "tickets")) and
                std.mem.eql(u8, field, "id_cliente")) or
                (std.mem.eql(u8, entity, "productos_carritos") and std.mem.eql(u8, field, "id_descuento"));
            try expect(@field(fields, field).nullable == optional);
        }
    }
    try expect(@FieldType(supermarket.Carrito, "id_cliente") == ?i64);
    try expect(@FieldType(supermarket.Ticket, "id_cliente") == ?i64);
    try expect(@FieldType(supermarket.ProductoCarrito, "id_descuento") == ?i64);
    try expect(@FieldType(supermarket.ProductoCarrito, "id_precio") == i64);
}

test "las versiones son únicas por producto e instante y exponen una clave que incluye al producto" {
    inline for (.{ "productos_precios", "descuentos_cantidad" }) |entity| {
        const info = @field(Model.info, entity);
        try expectNames(info.pk, &.{"id"});
        try expectNames(info.uks.producto_vigencia, &.{ "id_producto", "vigencia_desde" });
        try expectNames(info.uks.producto_id, &.{ "id_producto", "id" });
    }
    try expectNames(Model.info.tickets.uks.carrito, &.{"id_carrito"});
}

test "el detalle del carrito referencia versiones de precio y promoción de su propio producto" {
    const price = Model.info.productos_carritos.fks.precio;
    const promotion = Model.info.productos_carritos.fks.descuento;
    try std.testing.expectEqualStrings("productos_precios", price.entity);
    try std.testing.expectEqualStrings("id_producto", price.fields.id_producto);
    try std.testing.expectEqualStrings("id", price.fields.id_precio);
    try expect(@typeInfo(@TypeOf(price.fields)).@"struct".field_names.len == 2);
    try std.testing.expectEqualStrings("descuentos_cantidad", promotion.entity);
    try std.testing.expectEqualStrings("id_producto", promotion.fields.id_producto);
    try std.testing.expectEqualStrings("id", promotion.fields.id_descuento);
    try expect(@typeInfo(@TypeOf(promotion.fields)).@"struct".field_names.len == 2);
}

test "los importes usan centavos enteros exactos y los instantes tienen un dominio propio" {
    try expect(@FieldType(supermarket.ProductoPrecio, "precio") == i64);
    try expect(@FieldType(supermarket.Ticket, "total") == i64);
    try expect(@FieldType(supermarket.TicketProducto, "precio_unitario") == i64);
    try expect(@FieldType(supermarket.TicketProducto, "importe_descuento") == i64);
    try std.testing.expectEqualStrings("importe", Model.info.productos_precios.fields.precio.type);
    try std.testing.expectEqualStrings("instante", Model.info.carritos.fields.fecha_inicio.type);
    try std.testing.expectEqualStrings("instante", Model.info.productos_precios.fields.vigencia_desde.type);
    try expect(@FieldType(supermarket.Carrito, "fecha_inicio") == []const u8);
}

test "los totales del carrito se calculan y los tickets conservan las cantidades e importes finales" {
    try expect(!@hasField(supermarket.Carrito, "subtotal"));
    try expect(!@hasField(supermarket.Carrito, "total"));
    try expect(!@hasField(supermarket.Ticket, "fecha_emision_carrito"));
    try expect(@FieldType(supermarket.TicketProducto, "cantidad") == i64);
    try expect(@hasField(supermarket.Ticket, "fecha_emision"));
    try expect(@hasField(supermarket.TicketProducto, "precio_unitario"));
    try expect(@hasField(supermarket.TicketProducto, "importe_descuento"));
}

test "los carritos anónimos y los detalles sin descuento son valores tipados válidos" {
    const cart: supermarket.Carrito = .{
        .id = 1,
        .fecha_inicio = "2026-11-11T10:00:00.000Z",
        .estado = "abierto",
        .id_cliente = null,
    };
    const detail: supermarket.ProductoCarrito = .{
        .id_carrito = cart.id,
        .id_producto = 2,
        .cantidad = 4,
        .id_precio = 7,
        .id_descuento = null,
    };
    try expect(cart.id_cliente == null);
    try expect(detail.id_descuento == null and detail.id_precio == 7 and detail.cantidad == 4);
}
