//! Selección histórica y cálculo monetario puro, sin reloj, conexiones ni mutaciones.
const std = @import("std");
const contract = @import("contract");

pub const LineAmounts = struct {
    bruto: i64,
    descuento: i64,
    total: i64,
};

pub const CalculationError = error{
    InvalidQuantity,
    InvalidPrice,
    InvalidPromotionQuantity,
    InvalidPercentage,
    AmountOverflow,
};

/// Devuelve una copia de la fila elegida; sus strings siguen perteneciendo al llamador.
/// Las versiones deben respetar la UK (id_producto, vigencia_desde) del modelo.
pub fn selectPrice(
    versions: []const contract.ProductoPrecio,
    product_id: i64,
    opened_at: []const u8,
) error{ InvalidInstant, PriceNotFound }!contract.ProductoPrecio {
    return (try selectVersion(contract.ProductoPrecio, versions, product_id, opened_at)) orelse error.PriceNotFound;
}

/// Se selecciona antes de consultar activo: una desactivación reemplaza al estado anterior.
pub fn selectPromotion(
    versions: []const contract.DescuentoCantidad,
    product_id: i64,
    opened_at: []const u8,
) error{InvalidInstant}!?contract.DescuentoCantidad {
    const selected = (try selectVersion(contract.DescuentoCantidad, versions, product_id, opened_at)) orelse return null;
    return if (selected.activo) selected else null;
}

fn selectVersion(
    comptime Version: type,
    versions: []const Version,
    product_id: i64,
    opened_at: []const u8,
) error{InvalidInstant}!?Version {
    try validateInstant(opened_at);
    var selected: ?Version = null;
    for (versions) |version| {
        if (version.id_producto != product_id) continue;
        try validateInstant(version.vigencia_desde);
        // UTC y precisión fija hacen coincidir el orden textual con el cronológico.
        if (std.mem.order(u8, version.vigencia_desde, opened_at) == .gt) continue;
        if (selected == null or std.mem.order(u8, version.vigencia_desde, selected.?.vigencia_desde) == .gt)
            selected = version;
    }
    return selected;
}

/// Acepta solamente el formato UTC canónico acordado y fechas gregorianas existentes.
fn validateInstant(value: []const u8) error{InvalidInstant}!void {
    _ = @import("instant").parseCanonical(value) catch return error.InvalidInstant;
}

/// Cantidades y precio positivos. Una promoción ausente o inactiva no aplica descuento.
/// El redondeo se realiza una sola vez por renglón, al centavo, con mitades hacia arriba.
pub fn calculateLine(
    quantity: i64,
    unit_price: i64,
    promotion: ?contract.DescuentoCantidad,
) CalculationError!LineAmounts {
    if (quantity <= 0) return error.InvalidQuantity;
    if (unit_price <= 0) return error.InvalidPrice;
    // El producto de dos i64 positivos cabe en i128; se comprueba antes de estrecharlo.
    const gross_wide = @as(i128, quantity) * unit_price;
    if (gross_wide > std.math.maxInt(i64)) return error.AmountOverflow;
    const gross: i64 = @intCast(gross_wide);
    var discount: i64 = 0;
    if (promotion) |offer| {
        if (offer.activo) {
            if (offer.cantidad_llevar <= 0) return error.InvalidPromotionQuantity;
            if (offer.descuento_porcentaje < 1 or offer.descuento_porcentaje > 100)
                return error.InvalidPercentage;
            const groups = @divTrunc(quantity, offer.cantidad_llevar);
            const discounted_units = groups * offer.cantidad_llevar; // Nunca supera quantity.
            // El bruto ya cabe en i64: multiplicarlo por un porcentaje <=100 cabe en i128.
            const numerator = @as(i128, discounted_units) * unit_price * offer.descuento_porcentaje;
            discount = @intCast(@divTrunc(numerator + 50, 100));
        }
    }
    return .{ .bruto = gross, .descuento = discount, .total = gross - discount };
}
