//! Estructura SQL generada; no demuestra ejecución de CHECKs, triggers ni transacciones.
const std = @import("std");
const postgres = @import("postgres");
const migrations = @import("zigma_postgres_migrations");
const expect = std.testing.expect;

fn table(snapshot: migrations.Snapshot, name: []const u8) !migrations.Table {
    for (snapshot.tables) |value| if (std.mem.eql(u8, value.name, name)) return value;
    return error.MissingTable;
}

fn column(relation: migrations.Table, name: []const u8) !migrations.Column {
    for (relation.columns) |value| if (std.mem.eql(u8, value.name, name)) return value;
    return error.MissingColumn;
}

fn namesEqual(actual: []const []const u8, expected: []const []const u8) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |left, right| if (!std.mem.eql(u8, left, right)) return false;
    return true;
}

fn hasUnique(relation: migrations.Table, fields: []const []const u8) bool {
    for (relation.unique_keys) |key| if (namesEqual(key.columns, fields)) return true;
    return false;
}

fn hasForeignKey(relation: migrations.Table, fields: []const []const u8, target: []const u8, target_fields: []const []const u8) bool {
    for (relation.foreign_keys) |fk| {
        if (namesEqual(fk.columns, fields) and std.mem.eql(u8, fk.target_table, target) and namesEqual(fk.target_columns, target_fields))
            return true;
    }
    return false;
}

test "el esquema contiene exactamente las ocho tablas del supermercado con las claves primarias acordadas" {
    var parsed = try migrations.parseSnapshot(std.testing.allocator, postgres.schema_snapshot);
    defer parsed.deinit();
    try expect(parsed.value.tables.len == 8);
    for ([_][]const u8{ "productos", "productos_precios", "clientes", "carritos", "descuentos_cantidad", "tickets" }) |name| {
        try expect(namesEqual((try table(parsed.value, name)).primary_key.columns, &.{"id"}));
    }
    try expect(namesEqual((try table(parsed.value, "productos_carritos")).primary_key.columns, &.{ "id_carrito", "id_producto" }));
    try expect(namesEqual((try table(parsed.value, "tickets_productos")).primary_key.columns, &.{ "id_ticket", "id_producto" }));
}

test "las claves únicas SQL impiden versiones duplicadas y dos tickets para un mismo carrito" {
    var parsed = try migrations.parseSnapshot(std.testing.allocator, postgres.schema_snapshot);
    defer parsed.deinit();
    for ([_][]const u8{ "productos_precios", "descuentos_cantidad" }) |name| {
        const relation = try table(parsed.value, name);
        try expect(hasUnique(relation, &.{ "id_producto", "vigencia_desde" }));
        try expect(hasUnique(relation, &.{ "id_producto", "id" }));
    }
    try expect(hasUnique(try table(parsed.value, "tickets"), &.{"id_carrito"}));
}

test "las referencias SQL vinculan precios y promociones del mismo producto y todas las relaciones de pertenencia" {
    var parsed = try migrations.parseSnapshot(std.testing.allocator, postgres.schema_snapshot);
    defer parsed.deinit();
    const cases = [_]struct { source: []const u8, fields: []const []const u8, target: []const u8, target_fields: []const []const u8 }{
        .{ .source = "productos_precios", .fields = &.{"id_producto"}, .target = "productos", .target_fields = &.{"id"} },
        .{ .source = "descuentos_cantidad", .fields = &.{"id_producto"}, .target = "productos", .target_fields = &.{"id"} },
        .{ .source = "carritos", .fields = &.{"id_cliente"}, .target = "clientes", .target_fields = &.{"id"} },
        .{ .source = "productos_carritos", .fields = &.{"id_carrito"}, .target = "carritos", .target_fields = &.{"id"} },
        .{ .source = "productos_carritos", .fields = &.{"id_producto"}, .target = "productos", .target_fields = &.{"id"} },
        .{ .source = "productos_carritos", .fields = &.{ "id_producto", "id_precio" }, .target = "productos_precios", .target_fields = &.{ "id_producto", "id" } },
        .{ .source = "productos_carritos", .fields = &.{ "id_producto", "id_descuento" }, .target = "descuentos_cantidad", .target_fields = &.{ "id_producto", "id" } },
        .{ .source = "tickets", .fields = &.{"id_carrito"}, .target = "carritos", .target_fields = &.{"id"} },
        .{ .source = "tickets", .fields = &.{"id_cliente"}, .target = "clientes", .target_fields = &.{"id"} },
        .{ .source = "tickets_productos", .fields = &.{"id_ticket"}, .target = "tickets", .target_fields = &.{"id"} },
        .{ .source = "tickets_productos", .fields = &.{"id_producto"}, .target = "productos", .target_fields = &.{"id"} },
    };
    for (cases) |case|
        try expect(hasForeignKey(try table(parsed.value, case.source), case.fields, case.target, case.target_fields));
    try expect(std.mem.indexOf(u8, postgres.baseline_ddl, "FOREIGN KEY (\"id_producto\", \"id_precio\") REFERENCES \"productos_precios\" (\"id_producto\", \"id\")") != null);
    try expect(std.mem.indexOf(u8, postgres.baseline_ddl, "FOREIGN KEY (\"id_producto\", \"id_descuento\") REFERENCES \"descuentos_cantidad\" (\"id_producto\", \"id\")") != null);
}

test "SQL almacena centavos enteros, usa TIMESTAMPTZ y conserva las referencias opcionales" {
    var parsed = try migrations.parseSnapshot(std.testing.allocator, postgres.schema_snapshot);
    defer parsed.deinit();
    const prices = try table(parsed.value, "productos_precios");
    const carts = try table(parsed.value, "carritos");
    const details = try table(parsed.value, "productos_carritos");
    const tickets = try table(parsed.value, "tickets");
    try std.testing.expectEqualStrings("BIGINT", (try column(prices, "precio")).sql_type);
    try std.testing.expectEqualStrings("TIMESTAMPTZ", (try column(prices, "vigencia_desde")).sql_type);
    try std.testing.expectEqualStrings("TIMESTAMPTZ", (try column(carts, "fecha_inicio")).sql_type);
    try std.testing.expectEqualStrings("TIMESTAMPTZ", (try column(tickets, "fecha_emision")).sql_type);
    try expect((try column(carts, "id_cliente")).nullable);
    try expect((try column(tickets, "id_cliente")).nullable);
    try expect((try column(details, "id_descuento")).nullable);
    try expect(!(try column(details, "id_producto")).nullable);
    try expect(!(try column(details, "id_precio")).nullable);
    try expect(!(try column(details, "cantidad")).nullable);
    try expect(std.mem.indexOf(u8, postgres.baseline_ddl, "IF NOT EXISTS") == null);
}
