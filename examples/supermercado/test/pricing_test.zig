//! Políticas puras: el instante de referencia es la apertura, nunca el reloj actual.
const std = @import("std");
const supermarket = @import("supermercado");
const pricing = @import("pricing");
const expect = std.testing.expect;
const opening = "2026-11-11T10:00:00.000Z";
const before = "2026-11-10T09:00:00.000Z";
const after = "2026-11-11T10:05:00.000Z";

fn price(id: i64, product: i64, since: []const u8, cents: i64) supermarket.ProductoPrecio {
    return .{ .id = id, .id_producto = product, .vigencia_desde = since, .precio = cents };
}

fn promotion(id: i64, product: i64, since: []const u8, quantity: i64, percentage: i64, active: bool) supermarket.DescuentoCantidad {
    return .{
        .id = id,
        .id_producto = product,
        .vigencia_desde = since,
        .cantidad_llevar = quantity,
        .descuento_porcentaje = percentage,
        .activo = active,
    };
}

test "se selecciona el último precio vigente del producto solicitado sin depender del orden de entrada" {
    const versions = [_]supermarket.ProductoPrecio{
        price(30, 1, after, 120000),   price(99, 2, opening, 1),
        price(20, 1, opening, 100000), price(10, 1, before, 90000),
    };
    const selected = try pricing.selectPrice(&versions, 1, opening);
    try expect(selected.id == 20 and selected.precio == 100000);
}

test "un producto agregado después de un cambio de precio conserva el precio vigente al abrir el carrito" {
    const original = [_]supermarket.ProductoPrecio{price(10, 1, before, 90000)};
    const extended = original ++ [_]supermarket.ProductoPrecio{price(20, 1, after, 120000)};
    const first = try pricing.selectPrice(&original, 1, opening);
    const later_in_same_cart = try pricing.selectPrice(&extended, 1, opening);
    const new_cart = try pricing.selectPrice(&extended, 1, after);
    try expect(first.id == later_in_same_cart.id and new_cart.id == 20);
}

test "un producto sin precio vigente no puede agregarse al carrito" {
    const versions = [_]supermarket.ProductoPrecio{ price(1, 1, after, 100), price(2, 2, before, 100) };
    try std.testing.expectError(error.PriceNotFound, pricing.selectPrice(&versions, 1, opening));
    try std.testing.expectError(error.PriceNotFound, pricing.selectPrice(&.{}, 1, opening));
}

test "las promociones se seleccionan al abrir el carrito sin interferencia de otros productos ni versiones futuras" {
    const versions = [_]supermarket.DescuentoCantidad{
        promotion(30, 1, after, 1, 50, true),   promotion(99, 2, opening, 1, 100, true),
        promotion(20, 1, opening, 3, 10, true), promotion(10, 1, before, 1, 5, true),
    };
    const selected = (try pricing.selectPromotion(&versions, 1, opening)).?;
    try expect(selected.id == 20 and selected.cantidad_llevar == 3 and selected.descuento_porcentaje == 10);
}

test "la última versión inactiva deshabilita la promoción sin reactivar una versión anterior" {
    const versions = [_]supermarket.DescuentoCantidad{
        promotion(20, 1, opening, 3, 10, false), promotion(10, 1, before, 3, 10, true),
    };
    try expect((try pricing.selectPromotion(&versions, 1, opening)) == null);
    try expect((try pricing.selectPromotion(&versions, 1, before)).?.id == 10);
}

test "la desactivación posterior no afecta al carrito anterior y se permite la ausencia de promoción" {
    const versions = [_]supermarket.DescuentoCantidad{
        promotion(20, 1, after, 3, 10, false), promotion(10, 1, before, 3, 10, true),
    };
    try expect((try pricing.selectPromotion(&versions, 1, opening)).?.id == 10);
    try expect((try pricing.selectPromotion(&versions, 1, after)) == null);
    try expect((try pricing.selectPromotion(&versions, 2, opening)) == null);
    try expect((try pricing.selectPromotion(&.{}, 1, opening)) == null);
}

test "se rechazan los instantes de apertura inválidos antes de compararlos como texto" {
    const versions = [_]supermarket.ProductoPrecio{price(1, 1, before, 100)};
    inline for (.{ "", "yesterday", "2026-02-30T10:00:00.000Z", "2026-11-11T25:00:00.000Z" }) |invalid| {
        try std.testing.expectError(error.InvalidInstant, pricing.selectPrice(&versions, 1, invalid));
        try std.testing.expectError(error.InvalidInstant, pricing.selectPromotion(&.{}, 1, invalid));
    }
}

test "un renglón sin descuento conserva los centavos exactos" {
    const line = try pricing.calculateLine(4, 100000, null);
    try expect(line.bruto == 400000 and line.descuento == 0 and line.total == 400000);
}

test "solo los grupos completos reciben descuento al aumentar y disminuir las cantidades" {
    const offer = promotion(1, 1, before, 3, 10, true);
    for ([_]struct { quantity: i64, discount: i64, total: i64 }{
        .{ .quantity = 2, .discount = 0, .total = 200000 },
        .{ .quantity = 3, .discount = 30000, .total = 270000 },
        .{ .quantity = 4, .discount = 30000, .total = 370000 },
        .{ .quantity = 6, .discount = 60000, .total = 540000 },
        .{ .quantity = 7, .discount = 60000, .total = 640000 },
        .{ .quantity = 2, .discount = 0, .total = 200000 },
    }) |case| {
        const line = try pricing.calculateLine(case.quantity, 100000, offer);
        try expect(line.bruto == case.quantity * 100000);
        try expect(line.descuento == case.discount and line.total == case.total);
    }
}

test "un grupo de una unidad descuenta cada producto y un descuento del cien por ciento deja el renglón gratis" {
    const individual = try pricing.calculateLine(4, 100000, promotion(1, 1, before, 1, 10, true));
    const free = try pricing.calculateLine(3, 100000, promotion(1, 1, before, 3, 100, true));
    try expect(individual.descuento == 40000 and individual.total == 360000);
    try expect(free.descuento == 300000 and free.total == 0);
}

test "el descuento se redondea una vez por renglón y las mitades se redondean hacia arriba" {
    const offer = promotion(1, 1, before, 1, 10, true);
    const half_cent = try pricing.calculateLine(1, 5, offer);
    const two_units = try pricing.calculateLine(2, 5, offer);
    try expect(half_cent.descuento == 1 and half_cent.total == 4);
    try expect(two_units.descuento == 1 and two_units.total == 9);
}

test "las promociones inactivas no reducen el importe del renglón" {
    const line = try pricing.calculateLine(3, 100, promotion(1, 1, before, 3, 10, false));
    try expect(line.descuento == 0 and line.total == 300);
}

test "se rechazan cantidades, precios y parámetros de promoción inválidos" {
    inline for (.{ @as(i64, 0), @as(i64, -1) }) |invalid| {
        try std.testing.expectError(error.InvalidQuantity, pricing.calculateLine(invalid, 100, null));
        try std.testing.expectError(error.InvalidPrice, pricing.calculateLine(1, invalid, null));
        try std.testing.expectError(error.InvalidPromotionQuantity, pricing.calculateLine(1, 100, promotion(1, 1, before, invalid, 10, true)));
    }
    inline for (.{ @as(i64, 0), @as(i64, -1), @as(i64, 101) }) |invalid| {
        try std.testing.expectError(error.InvalidPercentage, pricing.calculateLine(1, 100, promotion(1, 1, before, 1, invalid, true)));
    }
}

test "se informa el desbordamiento y los descuentos grandes válidos usan cálculos intermedios de suficiente amplitud" {
    const max = std.math.maxInt(i64);
    try std.testing.expectError(error.AmountOverflow, pricing.calculateLine(2, max, null));
    const line = try pricing.calculateLine(1, max, promotion(1, 1, before, 1, 100, true));
    try expect(line.bruto == max and line.descuento == max and line.total == 0);
}
