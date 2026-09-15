const std = @import("std");
const zigma = @import("zigma");
const contract = @import("compile_errors/fixtures/model_contract.zig");
const Model = contract.Model;

test "system rows apply normalized composite PK semantics" {
    const Record = zigma.RecordInstanceType(zigma.common_type_defs, contract.fields);
    const Row = Model.Row("things");
    try std.testing.expect(@FieldType(Record, "tenant") == ?[]const u8);
    try std.testing.expect(@FieldType(Record, "id") == ?i64);
    try std.testing.expect(@FieldType(Row, "tenant") == []const u8);
    try std.testing.expect(@FieldType(Row, "id") == i64);
    try std.testing.expect(@FieldType(Row, "name") == []const u8);
    try std.testing.expect(@FieldType(Row, "note") == ?[]const u8);
    try std.testing.expect(@FieldType(Row, "active") == bool);

    const row: Row = .{ .tenant = "acme", .id = 7, .name = "Ada", .note = null, .active = true };
    try std.testing.expect(row.id == 7 and row.note == null);
    try std.testing.expect(Model.info.things.pk.len == 2);
    try std.testing.expectEqualStrings("tenant", Model.info.things.pk[0]);
    try std.testing.expectEqualStrings("id", Model.info.things.pk[1]);
    try std.testing.expect(!Model.info.things.fields.tenant.nullable);
    try std.testing.expect(!Model.info.things.fields.id.nullable);
    try std.testing.expectEqualStrings("tenant", Model.info.things.fks.parent.fields.tenant);
    try std.testing.expectEqualStrings("id", Model.info.things.fks.parent.fields.id);
}

test "projections preserve selected order and effective field types" {
    const Input = Model.Projection("things", .{ "note", "id" });
    const names = @typeInfo(Input).@"struct".field_names;
    try std.testing.expect(names.len == 2);
    try std.testing.expectEqualStrings("note", names[0]);
    try std.testing.expectEqualStrings("id", names[1]);
    try std.testing.expect(@FieldType(Input, "note") == ?[]const u8);
    try std.testing.expect(@FieldType(Input, "id") == i64);
    const input: Input = .{ .note = null, .id = 7 };
    try std.testing.expect(input.note == null and input.id == 7);
}

test "empty projections generate a valid empty struct" {
    const Empty = Model.Projection("things", .{});
    const value: Empty = .{};
    _ = value;
    try std.testing.expect(@typeInfo(Empty).@"struct".field_names.len == 0);
}

test "normalized metadata makes field defaults and empty rules explicit" {
    const info = Model.info.things;
    try std.testing.expectEqualStrings("note", info.fields.note.label);
    try std.testing.expectEqualStrings("", info.fields.note.description);
    try std.testing.expect(!info.fields.note.is_name);
    try std.testing.expect(info.fields.note.nullable);
    try std.testing.expect(@typeInfo(@TypeOf(info.rules)).@"struct".field_names.len == 0);
}

test "patches distinguish omission, explicit null, and a supplied value" {
    const Patch = Model.Patch("things");
    try std.testing.expect(!@hasField(Patch, "tenant"));
    try std.testing.expect(!@hasField(Patch, "id"));
    var patch: Patch = .{};
    try std.testing.expect(patch.name == .unset);
    try std.testing.expect(patch.note == .unset);
    try std.testing.expect(patch.active == .unset);

    patch.note = .{ .set = null };
    try std.testing.expect(patch.note == .set);
    try std.testing.expect(patch.note.set == null);
    patch.note = .{ .set = "null" };
    try std.testing.expectEqualStrings("null", patch.note.set.?);
    patch.active = .{ .set = false };
    try std.testing.expect(patch.active == .set and !patch.active.set);
    try std.testing.expect(patch.name == .unset);
}

test "filters use optional non-null domain values even for nullable columns" {
    const Filters = Model.Filters("things");
    try std.testing.expect(@FieldType(Filters, "id") == ?i64);
    try std.testing.expect(@FieldType(Filters, "note") == ?[]const u8);
    try std.testing.expect(@FieldType(Filters, "active") == ?bool);
    var filters: Filters = .{};
    try std.testing.expect(filters.tenant == null and filters.id == null);
    try std.testing.expect(filters.note == null and filters.active == null);
    filters.note = "null";
    filters.id = 7;
    filters.active = false;
    try std.testing.expectEqualStrings("null", filters.note.?);
    try std.testing.expect(filters.id.? == 7 and !filters.active.?);
}

test "rule inputs derive types from contract dependencies" {
    const entity = comptime zigma.defineEntity(.{
        .pk = .{"id"},
        .fields = contract.fields,
        .rules = .{
            .display = .{ .fields = .{ "note", "name" } },
            .identity = .{ .fields = .{"id"} },
        },
    });
    const RuleModel = zigma.System(zigma.common_type_defs, .{ .things = entity });
    const Input = RuleModel.RuleInput("things", "display");
    try std.testing.expect(Input == RuleModel.Projection("things", .{ "note", "name" }));
    try std.testing.expect(@FieldType(Input, "note") == ?[]const u8);
    try std.testing.expect(@FieldType(Input, "name") == []const u8);
    try std.testing.expect(@FieldType(RuleModel.RuleInput("things", "identity"), "id") == i64);

    const rules = RuleModel.info.things.rules;
    const names = @typeInfo(@TypeOf(rules)).@"struct".field_names;
    try std.testing.expectEqualStrings("display", names[0]);
    try std.testing.expectEqualStrings("identity", names[1]);
    try std.testing.expectEqualStrings("note", rules.display.fields[0]);
}

test "normalized metadata including rule descriptions serializes without implementations" {
    const entity = comptime zigma.defineEntity(.{
        .pk = .{"id"},
        .fields = contract.fields,
        .rules = .{ .display = .{ .fields = .{ "note", "name" } } },
    });
    const RuleModel = zigma.System(zigma.common_type_defs, .{ .things = entity });
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var stringify: std.json.Stringify = .{ .writer = &output.writer };
    try stringify.write(RuleModel.info);
    const bytes = try output.toOwnedSlice();
    defer std.testing.allocator.free(bytes);

    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    const things = parsed.value.object.get("things").?.object;
    const fields = things.get("fields").?.object;
    try std.testing.expect(!fields.get("id").?.object.get("nullable").?.bool);
    try std.testing.expect(fields.get("note").?.object.get("nullable").?.bool);
    try std.testing.expectEqualStrings("integer", fields.get("id").?.object.get("type").?.string);
    const dependencies = things.get("rules").?.object.get("display").?.object.get("fields").?.array.items;
    try std.testing.expect(dependencies.len == 2);
    try std.testing.expectEqualStrings("note", dependencies[0].string);
    try std.testing.expectEqualStrings("name", dependencies[1].string);
}
