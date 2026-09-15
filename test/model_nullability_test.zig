const std = @import("std");
const zigma = @import("zigma");

test "record instances honor nullable defaults for every built-in domain" {
    const fields = zigma.record(zigma.common_type_defs, .{
        .text = .{ .type = "text" },
        .integer = .{ .type = "integer" },
        .boolean = .{ .type = "boolean" },
    });
    const Row = zigma.RecordInstanceType(zigma.common_type_defs, fields);
    try std.testing.expect(@FieldType(Row, "text") == ?[]const u8);
    try std.testing.expect(@FieldType(Row, "integer") == ?i64);
    try std.testing.expect(@FieldType(Row, "boolean") == ?bool);
}

test "explicit nullable fields generate optional domain values" {
    const fields = zigma.record(zigma.common_type_defs, .{
        .value = .{ .type = "integer", .nullable = true },
    });
    const Row = zigma.RecordInstanceType(zigma.common_type_defs, fields);
    try std.testing.expect(@FieldType(Row, "value") == ?i64);
}

test "explicit required fields remain non-optional" {
    const fields = zigma.record(zigma.common_type_defs, .{
        .value = .{ .type = "integer", .nullable = false },
    });
    const Row = zigma.RecordInstanceType(zigma.common_type_defs, fields);
    try std.testing.expect(@FieldType(Row, "value") == i64);
    const row: Row = .{ .value = 42 };
    try std.testing.expect(row.value == 42);
}

test "entity completion resolves PK nullability without changing shared records" {
    const fields = zigma.record(zigma.common_type_defs, .{
        .id = .{ .type = "integer", .nullable = true },
        .note = .{ .type = "text" },
    });
    const entity = comptime zigma.defineEntity(.{ .pk = .{"id"}, .fields = fields });
    const record_info = zigma.completeRecord(fields);
    const entity_info = zigma.completeEntity(entity);
    try std.testing.expect(record_info.id.nullable);
    try std.testing.expect(!entity_info.fields.id.nullable);
    try std.testing.expect(entity_info.fields.note.nullable);
    try std.testing.expect(fields.id.nullable);
}
