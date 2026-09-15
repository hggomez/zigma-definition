const std = @import("std");
const zigma = @import("zigma");
const aida = @import("aida");
const ddl = @import("zigma_postgres_ddl");
const migrations = @import("zigma_postgres_migrations");

const mappings = ddl.defineTypeMappings(zigma.merge(.{
    ddl.common_type_mappings,
    .{
        .fecha = ddl.TypeMapping{ .sql_type = "DATE" },
        .email = ddl.TypeMapping{ .sql_type = "TEXT" },
    },
}));

const base_fields = zigma.record(zigma.common_type_defs, .{
    .id = .{ .type = "integer" },
    .name = .{ .type = "text", .nullable = false },
});
const base_entity = zigma.defineEntity(.{
    .fields = base_fields,
    .pk = .{"id"},
});
const base_defs = zigma.defineEntities(.{ .things = base_entity });

const extended_fields = zigma.record(zigma.common_type_defs, .{
    .id = .{ .type = "integer" },
    .name = .{ .type = "text" },
    .note = .{ .type = "text" },
});
const extended_entity = zigma.defineEntity(.{
    .fields = extended_fields,
    .pk = .{"id"},
    .uks = .{ .by_name = .{"name"} },
});
const extended_defs = zigma.defineEntities(.{ .things = extended_entity });

const unsafe_fields = zigma.record(zigma.common_type_defs, .{
    .id = .{ .type = "integer" },
    .renamed = .{ .type = "boolean", .nullable = false },
});
const unsafe_entity = zigma.defineEntity(.{
    .fields = unsafe_fields,
    .pk = .{"id"},
});
const unsafe_defs = zigma.defineEntities(.{ .things = unsafe_entity });

const empty_snapshot =
    \\{"format_version":1,"dialect":"postgresql","tables":[]}
;
const id_snapshot =
    \\{"format_version":1,"dialect":"postgresql","tables":[{"name":"things","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false}],"primary_key":{"name":"pk_things","columns":["id"]},"unique_keys":[],"foreign_keys":[]}]}
;
const nullable_column_snapshot =
    \\{"format_version":1,"dialect":"postgresql","tables":[{"name":"things","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false},{"name":"note","domain_type":"text","sql_type":"TEXT","nullable":true}],"primary_key":{"name":"pk_things","columns":["id"]},"unique_keys":[],"foreign_keys":[]}]}
;
const required_column_snapshot =
    \\{"format_version":1,"dialect":"postgresql","tables":[{"name":"things","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false},{"name":"note","domain_type":"text","sql_type":"TEXT","nullable":false}],"primary_key":{"name":"pk_things","columns":["id"]},"unique_keys":[],"foreign_keys":[]}]}
;
const reordered_before_snapshot =
    \\{"format_version":1,"dialect":"postgresql","tables":[{"name":"things","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false},{"name":"name","domain_type":"text","sql_type":"TEXT","nullable":false}],"primary_key":{"name":"pk_things","columns":["id"]},"unique_keys":[],"foreign_keys":[]}]}
;
const reordered_after_snapshot =
    \\{"format_version":1,"dialect":"postgresql","tables":[{"name":"things","columns":[{"name":"name","domain_type":"text","sql_type":"TEXT","nullable":false},{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false}],"primary_key":{"name":"pk_things","columns":["id"]},"unique_keys":[],"foreign_keys":[]}]}
;
const bigint_name_snapshot =
    \\{"format_version":1,"dialect":"postgresql","tables":[{"name":"things","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false},{"name":"name","domain_type":"text","sql_type":"BIGINT","nullable":false}],"primary_key":{"name":"pk_things","columns":["id"]},"unique_keys":[],"foreign_keys":[]}]}
;
const email_domain_snapshot =
    \\{"format_version":1,"dialect":"postgresql","tables":[{"name":"things","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false},{"name":"name","domain_type":"email","sql_type":"TEXT","nullable":false}],"primary_key":{"name":"pk_things","columns":["id"]},"unique_keys":[],"foreign_keys":[]}]}
;
const composite_pk_snapshot =
    \\{"format_version":1,"dialect":"postgresql","tables":[{"name":"things","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false},{"name":"name","domain_type":"text","sql_type":"TEXT","nullable":false}],"primary_key":{"name":"pk_things","columns":["id","name"]},"unique_keys":[],"foreign_keys":[]}]}
;
const unique_key_snapshot =
    \\{"format_version":1,"dialect":"postgresql","tables":[{"name":"things","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false},{"name":"name","domain_type":"text","sql_type":"TEXT","nullable":false}],"primary_key":{"name":"pk_things","columns":["id"]},"unique_keys":[{"name":"uk_things_name","columns":["name"]}],"foreign_keys":[]}]}
;
const foreign_key_base_snapshot =
    \\{"format_version":1,"dialect":"postgresql","tables":[{"name":"parents","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false}],"primary_key":{"name":"pk_parents","columns":["id"]},"unique_keys":[],"foreign_keys":[]},{"name":"things","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false}],"primary_key":{"name":"pk_things","columns":["id"]},"unique_keys":[],"foreign_keys":[]}]}
;
const foreign_key_snapshot =
    \\{"format_version":1,"dialect":"postgresql","tables":[{"name":"parents","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false}],"primary_key":{"name":"pk_parents","columns":["id"]},"unique_keys":[],"foreign_keys":[]},{"name":"things","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false}],"primary_key":{"name":"pk_things","columns":["id"]},"unique_keys":[],"foreign_keys":[{"name":"fk_things_parent","columns":["id"],"target_table":"parents","target_columns":["id"]}]}]}
;

fn expectMigrationName(expected: []const u8, before: []const u8, after: []const u8) !void {
    const actual = try migrations.inferMigrationName(std.testing.allocator, before, after);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "single structural changes receive precise automatic migration names" {
    const cases = [_]struct {
        expected: []const u8,
        before: []const u8,
        after: []const u8,
    }{
        .{ .expected = "create_table_things", .before = empty_snapshot, .after = id_snapshot },
        .{ .expected = "remove_table_things", .before = id_snapshot, .after = empty_snapshot },
        .{ .expected = "add_things_note", .before = id_snapshot, .after = nullable_column_snapshot },
        .{ .expected = "add_things_note", .before = id_snapshot, .after = required_column_snapshot },
        .{ .expected = "remove_things_note", .before = nullable_column_snapshot, .after = id_snapshot },
        .{ .expected = "reorder_things_columns", .before = reordered_before_snapshot, .after = reordered_after_snapshot },
        .{ .expected = "change_things_name_type", .before = reordered_before_snapshot, .after = bigint_name_snapshot },
        .{ .expected = "make_things_note_nullable", .before = required_column_snapshot, .after = nullable_column_snapshot },
        .{ .expected = "make_things_note_not_null", .before = nullable_column_snapshot, .after = required_column_snapshot },
        .{ .expected = "change_things_name_domain", .before = reordered_before_snapshot, .after = email_domain_snapshot },
        .{ .expected = "change_things_primary_key", .before = reordered_before_snapshot, .after = composite_pk_snapshot },
        .{ .expected = "add_uk_things_name", .before = reordered_before_snapshot, .after = unique_key_snapshot },
        .{ .expected = "change_uk_things_name", .before = unique_key_snapshot, .after = reordered_before_snapshot },
        .{ .expected = "add_fk_things_parent", .before = foreign_key_base_snapshot, .after = foreign_key_snapshot },
        .{ .expected = "change_fk_things_parent", .before = foreign_key_snapshot, .after = foreign_key_base_snapshot },
    };

    for (cases) |case| try expectMigrationName(case.expected, case.before, case.after);
}

test "automatic migration names summarize multiple changes deterministically" {
    const before = migrations.createSchemaSnapshot(BaseModel, ddl.common_type_mappings);
    const after = migrations.createSchemaSnapshot(ExtendedModel, ddl.common_type_mappings);
    try expectMigrationName("update_things", before, after);
    try expectMigrationName("update_schema", comprehensive_before, comprehensive_after);

    const first = try migrations.inferMigrationName(std.testing.allocator, before, after);
    defer std.testing.allocator.free(first);
    const second = try migrations.inferMigrationName(std.testing.allocator, before, after);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
}

test "automatic migration names normalize identifiers to lowercase ASCII slugs" {
    const unusual =
        \\{"format_version":1,"dialect":"postgresql","tables":[{"name":"Tâ \"BLE___Name","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false}],"primary_key":{"name":"pk_unusual","columns":["id"]},"unique_keys":[],"foreign_keys":[]}]}
    ;
    try expectMigrationName("create_table_t_ble_name", empty_snapshot, unusual);
}

test "automatic migration naming rejects an unchanged schema" {
    try std.testing.expectError(
        error.SchemaUnchanged,
        migrations.inferMigrationName(std.testing.allocator, id_snapshot, id_snapshot),
    );
}

test "canonical AIDA snapshot parses and includes only database semantics" {
    const json = migrations.createSchemaSnapshot(aida.Model, mappings);
    var parsed = try migrations.parseSnapshot(std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u32, 1), parsed.value.format_version);
    try std.testing.expectEqualStrings("postgresql", parsed.value.dialect);
    try std.testing.expectEqual(@as(usize, 11), parsed.value.tables.len);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"domain_type\":\"fecha\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sql_type\":\"DATE\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "label") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "description") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "is_name") == null);
}

test "baseline DDL deliberately omits IF NOT EXISTS" {
    const sql = ddl.createBaselineDdl(BaseModel, ddl.common_type_mappings);
    try std.testing.expect(std.mem.startsWith(u8, sql, "CREATE TABLE \"things\""));
    try std.testing.expect(std.mem.indexOf(u8, sql, "IF NOT EXISTS") == null);
}

test "safe changes generate executable SQL without blockers" {
    const before = migrations.createSchemaSnapshot(BaseModel, ddl.common_type_mappings);
    const after = migrations.createSchemaSnapshot(ExtendedModel, ddl.common_type_mappings);
    const draft = try migrations.createMigrationDraft(std.testing.allocator, before, after, .{
        .revision = 2,
        .name = "extend_things",
    });
    defer draft.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), draft.blocker_count);
    try std.testing.expect(std.mem.indexOf(u8, draft.sql, "--changeset zigma:000002_extend_things") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.sql, "ALTER TABLE \"things\" ADD COLUMN \"note\" TEXT;") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.sql, "ALTER COLUMN \"name\" DROP NOT NULL;") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.sql, "ADD CONSTRAINT \"uk_things_by_name\" UNIQUE (\"name\")") != null);
}

test "unsafe changes are detected but never emitted destructively" {
    const before = migrations.createSchemaSnapshot(BaseModel, ddl.common_type_mappings);
    const after = migrations.createSchemaSnapshot(UnsafeModel, ddl.common_type_mappings);
    const draft = try migrations.createMigrationDraft(std.testing.allocator, before, after, .{
        .revision = 2,
        .name = "unsafe_change",
    });
    defer draft.deinit(std.testing.allocator);

    try std.testing.expect(draft.blocker_count >= 2);
    try std.testing.expect(std.mem.indexOf(u8, draft.sql, migrations.blocker_marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.sql, "\nALTER TABLE \"things\" DROP COLUMN") == null);
    try std.testing.expect(std.mem.indexOf(u8, draft.sql, "CASCADE") == null);
    try std.testing.expect(std.mem.indexOf(u8, draft.sql, "USING") == null);
}

test "same desired state produces a metadata-only changeset" {
    const snapshot = migrations.createSchemaSnapshot(BaseModel, ddl.common_type_mappings);
    const draft = try migrations.createMigrationDraft(std.testing.allocator, snapshot, snapshot, .{
        .revision = 2,
        .name = "noop",
    });
    defer draft.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), draft.blocker_count);
    try std.testing.expect(std.mem.indexOf(u8, draft.sql, "SELECT 1") != null);
}

const comprehensive_before =
    \\{"format_version":1,"dialect":"postgresql","tables":[
    \\{"name":"obsolete","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false}],"primary_key":{"name":"pk_obsolete","columns":["id"]},"unique_keys":[],"foreign_keys":[]},
    \\{"name":"target","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false}],"primary_key":{"name":"pk_target","columns":["id"]},"unique_keys":[],"foreign_keys":[]},
    \\{"name":"things","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false},{"name":"name","domain_type":"text","sql_type":"TEXT","nullable":false},{"name":"removed","domain_type":"text","sql_type":"TEXT","nullable":true},{"name":"tighten","domain_type":"text","sql_type":"TEXT","nullable":true},{"name":"relax","domain_type":"text","sql_type":"TEXT","nullable":false},{"name":"domain","domain_type":"text","sql_type":"TEXT","nullable":true}],"primary_key":{"name":"pk_things","columns":["id"]},"unique_keys":[{"name":"uk_things_old","columns":["name"]},{"name":"uk_things_changed","columns":["name"]}],"foreign_keys":[{"name":"fk_things_old","columns":["id"],"target_table":"target","target_columns":["id"]},{"name":"fk_things_changed","columns":["id"],"target_table":"target","target_columns":["id"]}]}
    \\]}
;

const comprehensive_after =
    \\{"format_version":1,"dialect":"postgresql","tables":[
    \\{"name":"new_table","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false}],"primary_key":{"name":"pk_new_table","columns":["id"]},"unique_keys":[],"foreign_keys":[]},
    \\{"name":"target","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false}],"primary_key":{"name":"pk_target","columns":["id"]},"unique_keys":[],"foreign_keys":[]},
    \\{"name":"things","columns":[{"name":"inserted","domain_type":"text","sql_type":"TEXT","nullable":true},{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false},{"name":"name","domain_type":"text","sql_type":"BIGINT","nullable":false},{"name":"tighten","domain_type":"text","sql_type":"TEXT","nullable":false},{"name":"relax","domain_type":"text","sql_type":"TEXT","nullable":true},{"name":"domain","domain_type":"email","sql_type":"TEXT","nullable":true},{"name":"new_nullable","domain_type":"text","sql_type":"TEXT","nullable":true},{"name":"new_required","domain_type":"text","sql_type":"TEXT","nullable":false}],"primary_key":{"name":"pk_things","columns":["id","name"]},"unique_keys":[{"name":"uk_things_changed","columns":["id"]},{"name":"uk_things_new","columns":["name"]}],"foreign_keys":[{"name":"fk_things_changed","columns":["name"],"target_table":"target","target_columns":["id"]},{"name":"fk_things_new","columns":["id"],"target_table":"target","target_columns":["id"]}]}
    \\]}
;

fn diffHasKind(diff: migrations.SchemaDiff, kind: migrations.ChangeKind) bool {
    for (diff.changes) |change| if (change.kind == kind) return true;
    return false;
}

test "structural diff classifies every supported change category" {
    const diff = try migrations.diffSnapshots(std.testing.allocator, comprehensive_before, comprehensive_after);
    defer diff.deinit();

    inline for (std.meta.tags(migrations.ChangeKind)) |kind|
        try std.testing.expect(diffHasKind(diff, kind));
}

test "a new column in the middle is a blocker and is not falsely emitted as appendable" {
    const draft = try migrations.createMigrationDraft(std.testing.allocator, comprehensive_before, comprehensive_after, .{
        .revision = 2,
        .name = "comprehensive",
    });
    defer draft.deinit(std.testing.allocator);

    try std.testing.expect(migrations.draftHasBlockers(draft.sql));
    try std.testing.expect(std.mem.indexOf(u8, draft.sql, "ADD COLUMN \"inserted\"") == null);
}

test "draft endpoint hashes reject stale source or desired snapshots" {
    const before = migrations.createSchemaSnapshot(BaseModel, ddl.common_type_mappings);
    const after = migrations.createSchemaSnapshot(ExtendedModel, ddl.common_type_mappings);
    const draft = try migrations.createMigrationDraft(std.testing.allocator, before, after, .{
        .revision = 2,
        .name = "hashes",
    });
    defer draft.deinit(std.testing.allocator);

    try std.testing.expect(migrations.draftMatchesSnapshots(draft.sql, before, after));
    try std.testing.expect(!migrations.draftMatchesSnapshots(draft.sql, after, after));
    try std.testing.expect(!migrations.draftMatchesSnapshots(draft.sql, before, before));
}

test "draft SQL doubles quotes in PostgreSQL identifiers" {
    const empty =
        \\{"format_version":1,"dialect":"postgresql","tables":[]}
    ;
    const quoted =
        \\{"format_version":1,"dialect":"postgresql","tables":[{"name":"ta\"ble","columns":[{"name":"co\"l","domain_type":"text","sql_type":"TEXT","nullable":false}],"primary_key":{"name":"pk_ta\"ble","columns":["co\"l"]},"unique_keys":[],"foreign_keys":[]}]}
    ;
    const draft = try migrations.createMigrationDraft(std.testing.allocator, empty, quoted, .{
        .revision = 2,
        .name = "quoted",
    });
    defer draft.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, draft.sql, "CREATE TABLE \"ta\"\"ble\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, draft.sql, "\"co\"\"l\" TEXT NOT NULL") != null);
}

const BaseModel = zigma.System(zigma.common_type_defs, base_defs);

const ExtendedModel = zigma.System(zigma.common_type_defs, extended_defs);

const UnsafeModel = zigma.System(zigma.common_type_defs, unsafe_defs);
