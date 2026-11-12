//! CRUD con validaciones por fila. La coordinación transaccional de caja es otra capa.
const std = @import("std");
const zigma = @import("zigma");
const rest = @import("zigma_rest");
const contract = @import("contract");
const instant_wire = @import("instant_wire.zig");

pub const codecs = rest.defineCodecs(contract.type_defs, zigma.merge(.{
    rest.common_codecs,
    .{ .importe = rest.integer_codec, .instante = instant_wire.codec },
}));

fn validatePrice(value: contract.ProductoPrecio, _: void) ?rest.BusinessRuleViolation {
    if (value.precio <= 0) return .{ .code = "price_must_be_positive", .message = "El precio debe ser positivo, expresado en centavos enteros" };
    return null;
}

fn validatePromotion(value: contract.DescuentoCantidad, _: void) ?rest.BusinessRuleViolation {
    if (value.cantidad_llevar <= 0 or value.descuento_porcentaje < 1 or value.descuento_porcentaje > 100)
        return .{ .code = "invalid_promotion", .message = "La promoción requiere un grupo positivo y un porcentaje entre 1 y 100" };
    return null;
}

fn validateCartLine(value: contract.ProductoCarrito, _: void) ?rest.BusinessRuleViolation {
    if (value.cantidad <= 0) return .{ .code = "quantity_must_be_positive", .message = "La cantidad debe ser positiva" };
    return null;
}

fn validateCart(value: contract.Carrito, _: void) ?rest.BusinessRuleViolation {
    for ([_][]const u8{ "abierto", "cerrado", "cancelado" }) |state| {
        if (std.mem.eql(u8, value.estado, state)) return null;
    }
    return .{ .code = "invalid_cart_state", .message = "El estado debe ser abierto, cerrado o cancelado" };
}

fn validateTicket(value: contract.Ticket, _: void) ?rest.BusinessRuleViolation {
    if (value.total < 0) return .{ .code = "invalid_ticket_total", .message = "El total del ticket no puede ser negativo" };
    return null;
}

fn validateTicketLine(value: contract.TicketProducto, _: void) ?rest.BusinessRuleViolation {
    // i128 permite comprobar el producto completo antes de exigir que quepa en i64.
    const gross = @as(i128, value.cantidad) * value.precio_unitario;
    if (value.cantidad <= 0 or value.precio_unitario <= 0 or gross > std.math.maxInt(i64) or
        value.importe_descuento < 0 or value.importe_descuento > gross)
        return .{ .code = "invalid_ticket_line", .message = "El renglón requiere cantidad y precio positivos, un bruto representable y un descuento entre cero y el bruto" };
    return null;
}

pub const business_validators = rest.defineBusinessValidators(contract.Model, .{
    .productos_precios = rest.BusinessValidator(contract.ProductoPrecio, void){ .validate = validatePrice },
    .descuentos_cantidad = rest.BusinessValidator(contract.DescuentoCantidad, void){ .validate = validatePromotion },
    .productos_carritos = rest.BusinessValidator(contract.ProductoCarrito, void){ .validate = validateCartLine },
    .carritos = rest.BusinessValidator(contract.Carrito, void){ .validate = validateCart },
    .tickets = rest.BusinessValidator(contract.Ticket, void){ .validate = validateTicket },
    .tickets_productos = rest.BusinessValidator(contract.TicketProducto, void){ .validate = validateTicketLine },
});

pub const Api = rest.Api(contract.Model, codecs, business_validators);
