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

test "canonical AIDA snapshot parses and includes only database semantics" {
    const json = migrations.createSchemaSnapshot(aida.entity_defs, mappings);
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
    const sql = ddl.createBaselineDdl(base_defs, ddl.common_type_mappings);
    try std.testing.expect(std.mem.startsWith(u8, sql, "CREATE TABLE \"things\""));
    try std.testing.expect(std.mem.indexOf(u8, sql, "IF NOT EXISTS") == null);
}

test "safe changes generate executable SQL without blockers" {
    const before = migrations.createSchemaSnapshot(base_defs, ddl.common_type_mappings);
    const after = migrations.createSchemaSnapshot(extended_defs, ddl.common_type_mappings);
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
    const before = migrations.createSchemaSnapshot(base_defs, ddl.common_type_mappings);
    const after = migrations.createSchemaSnapshot(unsafe_defs, ddl.common_type_mappings);
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
    const snapshot = migrations.createSchemaSnapshot(base_defs, ddl.common_type_mappings);
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
    const before = migrations.createSchemaSnapshot(base_defs, ddl.common_type_mappings);
    const after = migrations.createSchemaSnapshot(extended_defs, ddl.common_type_mappings);
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
