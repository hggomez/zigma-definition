//! Contrato del catálogo del frontend: metadatos y tipos provienen del mismo Model.
const std = @import("std");
const zigma = @import("zigma");
const json = @import("zigma_json");
const aida = @import("aida");
const tiny = @import("tiny_system.zig");

fn parse(bytes: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
}

fn field(entity: std.json.Value, name: []const u8) !std.json.Value {
    for (entity.object.get("fields").?.array.items) |value| {
        if (std.mem.eql(u8, value.object.get("name").?.string, name)) return value;
    }
    return error.MissingField;
}

test "catalogue uses effective entity nullability without changing the record" {
    const Model = zigma.Framework(tiny.type_defs, tiny.entity_defs);
    var buf: [2048]u8 = undefined;
    var parsed = try parse(try json.stringifyEntityCatalog(Model, &buf));
    defer parsed.deinit();
    try std.testing.expect(parsed.value.array.items.len == 1);
    const entity = parsed.value.array.items[0];
    try std.testing.expectEqualStrings("items", entity.object.get("name").?.string);
    try std.testing.expect(!(try field(entity, "id")).object.get("nullable").?.bool);
    try std.testing.expect((try field(entity, "nombre")).object.get("nullable").?.bool);
    try std.testing.expect(@FieldType(Model.Row("items"), "id") == []const u8);
    const Record = zigma.RecordInstanceType(tiny.type_defs, tiny.item);
    try std.testing.expect(@FieldType(Record, "id") == ?[]const u8);
}

test "catalogue preserves declaration order and composite primary key nullability" {
    var buf: [32768]u8 = undefined;
    var parsed = try parse(try json.stringifyEntityCatalog(aida.Model, &buf));
    defer parsed.deinit();
    const names = @typeInfo(@TypeOf(aida.Model.info)).@"struct".field_names;
    try std.testing.expect(parsed.value.array.items.len == names.len);
    inline for (names, 0..) |name, i| {
        const entity = parsed.value.array.items[i];
        try std.testing.expectEqualStrings(name, entity.object.get("name").?.string);
        const info = @field(aida.Model.info, name);
        const fields = @typeInfo(@TypeOf(info.fields)).@"struct".field_names;
        try std.testing.expect(entity.object.get("fields").?.array.items.len == fields.len);
        inline for (fields, 0..) |field_name, j| {
            const item = entity.object.get("fields").?.array.items[j];
            try std.testing.expectEqualStrings(field_name, item.object.get("name").?.string);
            try std.testing.expect(item.object.get("nullable").?.bool == @field(info.fields, field_name).nullable);
        }
        inline for (info.pk) |pk| try std.testing.expect(!(try field(entity, pk)).object.get("nullable").?.bool);
    }
}

test "nested optional structures retain their shape and child nullability" {
    const Inner = struct { count: i64, enabled: ?bool };
    const Details = struct { title: ?[]const u8, inner: ?Inner };
    const types = zigma.defineTypes(zigma.merge(.{ zigma.common_type_defs, .{ .details = .{ .Type = Details } } }));
    const rec = zigma.record(types, .{ .id = .{ .type = "text" }, .details = .{ .type = "details" } });
    const Model = zigma.Framework(types, .{ .entries = zigma.defineEntity(.{ .fields = rec, .pk = .{"id"} }) });
    var buf: [4096]u8 = undefined;
    var parsed = try parse(try json.stringifyEntitySchema(Model, "entries", &buf));
    defer parsed.deinit();
    const details = try field(parsed.value, "details");
    try std.testing.expectEqualStrings("details", details.object.get("type").?.string);
    try std.testing.expectEqualStrings("object", details.object.get("storage").?.string);
    try std.testing.expect(details.object.get("nullable").?.bool);
    try std.testing.expect((try field(details, "title")).object.get("nullable").?.bool);
    const inner = try field(details, "inner");
    try std.testing.expectEqualStrings("object", inner.object.get("storage").?.string);
    try std.testing.expect(inner.object.get("nullable").?.bool);
    try std.testing.expect(!(try field(inner, "count")).object.get("nullable").?.bool);
    try std.testing.expect((try field(inner, "enabled")).object.get("nullable").?.bool);
}

test "entity metadata escapes names labels and foreign key maps" {
    const entity_name = "items\"\\\nñ";
    const field_name = "id\"\\\n";
    const label = "Identificador \"público\"\\ruta\n\tñ";
    const rec = zigma.record(zigma.common_type_defs, .{
        .@"id\"\\\n" = .{ .type = "text", .label = label },
    });
    const Model = zigma.Framework(zigma.common_type_defs, .{
        .@"items\"\\\nñ" = zigma.defineEntity(.{
            .fields = rec,
            .pk = .{field_name},
            .uks = .{ .@"unique\"" = .{field_name} },
            .fks = .{ .@"self\"" = .{ .entity = entity_name, .fields = .{ .@"id\"\\\n" = field_name } } },
        }),
    });
    var buf: [2048]u8 = undefined;
    var parsed = try parse(try json.stringifyEntitySchema(Model, entity_name, &buf));
    defer parsed.deinit();
    const object = parsed.value.object;
    try std.testing.expectEqualStrings(entity_name, object.get("name").?.string);
    try std.testing.expectEqualStrings(field_name, object.get("pk").?.array.items[0].string);
    try std.testing.expectEqualStrings(label, (try field(parsed.value, field_name)).object.get("label").?.string);
    try std.testing.expectEqualStrings(field_name, object.get("uks").?.object.get("unique\"").?.array.items[0].string);
    const fk = object.get("fks").?.object.get("self\"").?.object;
    try std.testing.expectEqualStrings(entity_name, fk.get("entity").?.string);
    try std.testing.expectEqualStrings(field_name, fk.get("fields").?.object.get(field_name).?.string);
}

test "application rules do not change the frontend catalogue" {
    const base = zigma.Framework(tiny.type_defs, tiny.entity_defs);
    const with_rules = zigma.Framework(tiny.type_defs, .{ .items = zigma.defineEntity(.{
        .fields = tiny.item,
        .pk = .{"id"},
        .rules = .{ .named = .{ .fields = .{"nombre"} } },
    }) });
    var first: [2048]u8 = undefined;
    var second: [2048]u8 = undefined;
    try std.testing.expectEqualStrings(
        try json.stringifyEntityCatalog(base, &first),
        try json.stringifyEntityCatalog(with_rules, &second),
    );
}

test "entity and catalogue report insufficient buffers without truncating success" {
    const Model = zigma.Framework(tiny.type_defs, tiny.entity_defs);
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, json.stringifyEntitySchema(Model, "items", &small));
    try std.testing.expectError(error.NoSpaceLeft, json.stringifyEntityCatalog(Model, &small));
    var large: [2048]u8 = undefined;
    var parsed = try parse(try json.stringifyEntityCatalog(Model, &large));
    defer parsed.deinit();
    try std.testing.expectEqualStrings("items", parsed.value.array.items[0].object.get("name").?.string);
}
