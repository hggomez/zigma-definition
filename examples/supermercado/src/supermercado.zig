//! Contrato del supermercado: vocabulario, claves y relaciones del MER.
//! Las filas conservan datos; el cierre del carrito y la emisión del ticket
//! requieren un servicio transaccional, no se ejecutan al declarar el modelo.
const zigma = @import("zigma");

pub const type_defs = zigma.defineTypes(zigma.merge(.{
    zigma.common_type_defs,
    .{
        // Centavos enteros, sin representación de punto flotante.
        .importe = zigma.common_type_defs.integer,
        // UTC canónico: YYYY-MM-DDTHH:mm:ss.SSSZ. Las políticas validan su contenido.
        .instante = zigma.common_type_defs.text,
    },
}));

const identifier = .{ .type = "integer", .nullable = false };

pub const producto_def = zigma.entityDefinition(type_defs, .{
    .fields = .{
        .id = identifier,
        .nombre = .{ .type = "text", .nullable = false, .label = "Nombre", .is_name = true },
        .descripcion = .{ .type = "text", .nullable = false, .label = "Descripción" },
    },
    .pk = .{"id"},
});

pub const producto_precio_def = zigma.entityDefinition(type_defs, .{
    .fields = .{
        .id = identifier,
        .id_producto = identifier,
        .vigencia_desde = .{ .type = "instante", .nullable = false, .label = "Vigencia desde" },
        .precio = .{ .type = "importe", .nullable = false, .label = "Precio", .description = "Precio unitario en centavos" },
    },
    .pk = .{"id"},
    .uks = .{
        .producto_vigencia = .{ "id_producto", "vigencia_desde" },
        // Destino de la FK compuesta: el precio debe pertenecer al producto del renglón.
        .producto_id = .{ "id_producto", "id" },
    },
    .fks = .{ .producto = .{ .entity = "productos", .fields = .{ .id_producto = "id" } } },
});

pub const cliente_def = zigma.entityDefinition(type_defs, .{
    .fields = .{
        .id = identifier,
        .nombre = .{ .type = "text", .nullable = false, .label = "Nombre", .is_name = true },
    },
    .pk = .{"id"},
});

pub const carrito_def = zigma.entityDefinition(type_defs, .{
    .fields = .{
        .id = identifier,
        .fecha_inicio = .{ .type = "instante", .nullable = false, .label = "Fecha de apertura" },
        .estado = .{ .type = "text", .nullable = false, .label = "Estado", .description = "abierto, cerrado o cancelado; transiciones a cargo del servicio" },
        .id_cliente = .{ .type = "integer", .nullable = true, .label = "Cliente" },
    },
    .pk = .{"id"},
    .fks = .{ .cliente = .{ .entity = "clientes", .fields = .{ .id_cliente = "id" } } },
});

pub const descuento_cantidad_def = zigma.entityDefinition(type_defs, .{
    .fields = .{
        .id = identifier,
        .id_producto = identifier,
        .vigencia_desde = .{ .type = "instante", .nullable = false, .label = "Vigencia desde" },
        .cantidad_llevar = .{ .type = "integer", .nullable = false, .label = "Unidades por grupo" },
        .descuento_porcentaje = .{ .type = "integer", .nullable = false, .label = "Descuento (%)" },
        .activo = .{ .type = "boolean", .nullable = false, .label = "Activo" },
    },
    .pk = .{"id"},
    .uks = .{
        .producto_vigencia = .{ "id_producto", "vigencia_desde" },
        .producto_id = .{ "id_producto", "id" },
    },
    .fks = .{ .producto = .{ .entity = "productos", .fields = .{ .id_producto = "id" } } },
});

pub const producto_carrito_def = zigma.entityDefinition(type_defs, .{
    .fields = .{
        .id_carrito = identifier,
        .id_producto = identifier,
        .cantidad = .{ .type = "integer", .nullable = false, .label = "Cantidad" },
        .id_precio = identifier,
        .id_descuento = .{ .type = "integer", .nullable = true, .label = "Promoción" },
    },
    .pk = .{ "id_carrito", "id_producto" },
    .fks = .{
        .carrito = .{ .entity = "carritos", .fields = .{ .id_carrito = "id" } },
        .producto = .{ .entity = "productos", .fields = .{ .id_producto = "id" } },
        .precio = .{ .entity = "productos_precios", .fields = .{ .id_producto = "id_producto", .id_precio = "id" } },
        // MATCH SIMPLE permite id_descuento nulo, manteniendo obligatorio id_producto.
        .descuento = .{ .entity = "descuentos_cantidad", .fields = .{ .id_producto = "id_producto", .id_descuento = "id" } },
    },
});

pub const ticket_def = zigma.entityDefinition(type_defs, .{
    .fields = .{
        .id = identifier,
        .id_carrito = identifier,
        .fecha_emision = .{ .type = "instante", .nullable = false, .label = "Fecha de emisión" },
        .total = .{ .type = "importe", .nullable = false, .label = "Total", .description = "Importe final en centavos" },
        .id_cliente = .{ .type = "integer", .nullable = true, .label = "Cliente" },
    },
    .pk = .{"id"},
    .uks = .{ .carrito = .{"id_carrito"} },
    .fks = .{
        .carrito = .{ .entity = "carritos", .fields = .{ .id_carrito = "id" } },
        .cliente = .{ .entity = "clientes", .fields = .{ .id_cliente = "id" } },
    },
});

pub const ticket_producto_def = zigma.entityDefinition(type_defs, .{
    .fields = .{
        .id_ticket = identifier,
        .id_producto = identifier,
        .cantidad = .{ .type = "integer", .nullable = false, .label = "Cantidad" },
        .precio_unitario = .{ .type = "importe", .nullable = false, .label = "Precio unitario", .description = "Precio de venta en centavos" },
        .importe_descuento = .{ .type = "importe", .nullable = false, .label = "Descuento", .description = "Descuento definitivo del renglón en centavos" },
    },
    .pk = .{ "id_ticket", "id_producto" },
    .fks = .{
        .ticket = .{ .entity = "tickets", .fields = .{ .id_ticket = "id" } },
        .producto = .{ .entity = "productos", .fields = .{ .id_producto = "id" } },
    },
});

pub const Producto = zigma.Entity(type_defs, producto_def);
pub const ProductoPrecio = zigma.Entity(type_defs, producto_precio_def);
pub const Cliente = zigma.Entity(type_defs, cliente_def);
pub const Carrito = zigma.Entity(type_defs, carrito_def);
pub const ProductoCarrito = zigma.Entity(type_defs, producto_carrito_def);
pub const DescuentoCantidad = zigma.Entity(type_defs, descuento_cantidad_def);
pub const Ticket = zigma.Entity(type_defs, ticket_def);
pub const TicketProducto = zigma.Entity(type_defs, ticket_producto_def);

pub const entity_defs = zigma.defineEntities(.{
    .productos = .{ .Type = Producto, .definition = producto_def },
    .productos_precios = .{ .Type = ProductoPrecio, .definition = producto_precio_def },
    .clientes = .{ .Type = Cliente, .definition = cliente_def },
    .carritos = .{ .Type = Carrito, .definition = carrito_def },
    .productos_carritos = .{ .Type = ProductoCarrito, .definition = producto_carrito_def },
    .descuentos_cantidad = .{ .Type = DescuentoCantidad, .definition = descuento_cantidad_def },
    .tickets = .{ .Type = Ticket, .definition = ticket_def },
    .tickets_productos = .{ .Type = TicketProducto, .definition = ticket_producto_def },
});

pub const Model = zigma.Framework(type_defs, entity_defs);
