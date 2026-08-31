//! Pure desired-schema snapshots and PostgreSQL migration draft generation.
//!
//! The current entity definitions remain the desired-state source of truth.
//! This module serializes only their PostgreSQL-visible shape, compares that
//! shape with the last accepted snapshot, and renders a Liquibase formatted
//! SQL draft. It never reads files, starts processes, or connects to a
//! database.

const std = @import("std");
const zigma = @import("zigma");
const postgres_ddl = @import("zigma_postgres_ddl");

pub const snapshot_format_version = 1;
pub const dialect = "postgresql";
pub const blocker_marker = "ZIGMA-BLOCKER:";

pub const Column = struct {
    name: []const u8,
    domain_type: []const u8,
    sql_type: []const u8,
    nullable: bool,
};

pub const Key = struct {
    name: []const u8,
    columns: []const []const u8,
};

pub const ForeignKey = struct {
    name: []const u8,
    columns: []const []const u8,
    target_table: []const u8,
    target_columns: []const []const u8,
};

pub const Table = struct {
    name: []const u8,
    columns: []const Column,
    primary_key: Key,
    unique_keys: []const Key,
    foreign_keys: []const ForeignKey,
};

pub const Snapshot = struct {
    format_version: u32,
    dialect: []const u8,
    tables: []const Table,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn containsName(comptime names: anytype, comptime wanted: []const u8) bool {
    for (names) |name| if (eql(name, wanted)) return true;
    return false;
}

fn jsonEscape(comptime value: []const u8) []const u8 {
    comptime var result: []const u8 = "";
    inline for (value) |byte| {
        result = result ++ switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0...8, 11, 12, 14...31 => &[_]u8{
                '\\',                          'u',                             '0', '0',
                "0123456789abcdef"[byte >> 4], "0123456789abcdef"[byte & 0x0f],
            },
            else => &[_]u8{byte},
        };
    }
    return comptime result;
}

fn jsonString(comptime value: []const u8) []const u8 {
    return comptime "\"" ++ jsonEscape(value) ++ "\"";
}

fn jsonStringList(comptime values: anytype) []const u8 {
    comptime var result: []const u8 = "[";
    inline for (values, 0..) |value, index| {
        if (index != 0) result = result ++ ",";
        result = result ++ jsonString(value);
    }
    return result ++ "]";
}

fn jsonStructFieldNames(comptime StructType: type) []const u8 {
    return jsonStringList(@typeInfo(StructType).@"struct".field_names);
}

fn jsonStructFieldValues(comptime values: anytype) []const u8 {
    comptime var result: []const u8 = "[";
    inline for (@typeInfo(@TypeOf(values)).@"struct".field_names, 0..) |name, index| {
        if (index != 0) result = result ++ ",";
        result = result ++ jsonString(@field(values, name));
    }
    return result ++ "]";
}

fn renderSnapshot(comptime entity_defs: anytype, comptime type_mappings: anytype) []const u8 {
    @setEvalBranchQuota(1_000_000);
    // Reuse every validation performed by the DDL layer before serializing.
    _ = postgres_ddl.createSchemaDdl(entity_defs, type_mappings);
    const validated = zigma.defineEntities(entity_defs);

    comptime var json: []const u8 =
        "{\n" ++
        "  \"format_version\":1,\n" ++
        "  \"dialect\":\"postgresql\",\n" ++
        "  \"tables\":[\n";

    inline for (@typeInfo(@TypeOf(validated)).@"struct".field_names, 0..) |table_name, table_index| {
        const info = zigma.completeEntity(@field(validated, table_name));
        if (table_index != 0) json = json ++ ",\n";
        json = json ++ "    {\"name\":" ++ jsonString(table_name) ++ ",\"columns\":[";

        inline for (@typeInfo(@TypeOf(info.fields)).@"struct".field_names, 0..) |field_name, field_index| {
            const field = @field(info.fields, field_name);
            if (field_index != 0) json = json ++ ",";
            json = json ++
                "{\"name\":" ++ jsonString(field_name) ++
                ",\"domain_type\":" ++ jsonString(field.type) ++
                ",\"sql_type\":" ++ jsonString(@field(type_mappings, field.type).sql_type) ++
                ",\"nullable\":" ++ (if (field.nullable and !containsName(info.pk, field_name)) "true" else "false") ++ "}";
        }

        json = json ++ "],\"primary_key\":{\"name\":" ++ jsonString("pk_" ++ table_name) ++
            ",\"columns\":" ++ jsonStringList(info.pk) ++ "},\"unique_keys\":[";

        inline for (@typeInfo(@TypeOf(info.uks)).@"struct".field_names, 0..) |uk_name, uk_index| {
            if (uk_index != 0) json = json ++ ",";
            json = json ++ "{\"name\":" ++ jsonString("uk_" ++ table_name ++ "_" ++ uk_name) ++
                ",\"columns\":" ++ jsonStringList(@field(info.uks, uk_name)) ++ "}";
        }

        json = json ++ "],\"foreign_keys\":[";
        inline for (@typeInfo(@TypeOf(info.fks)).@"struct".field_names, 0..) |fk_name, fk_index| {
            const fk = @field(info.fks, fk_name);
            if (fk_index != 0) json = json ++ ",";
            json = json ++ "{\"name\":" ++ jsonString("fk_" ++ table_name ++ "_" ++ fk_name) ++
                ",\"columns\":" ++ jsonStructFieldNames(@TypeOf(fk.fields)) ++
                ",\"target_table\":" ++ jsonString(fk.entity) ++
                ",\"target_columns\":" ++ jsonStructFieldValues(fk.fields) ++ "}";
        }
        json = json ++ "]}";
    }

    return json ++ "\n  ]\n}\n";
}

/// Returns deterministic JSON for the PostgreSQL-visible desired schema.
pub fn createSchemaSnapshot(
    comptime entity_defs: anytype,
    comptime type_mappings: anytype,
) []const u8 {
    return comptime renderSnapshot(entity_defs, type_mappings);
}

/// Fails compilation when the desired schema differs from the committed
/// snapshot. A build-integrated checker can render the detailed runtime diff;
/// this assertion also protects direct compilation of an application root.
pub fn assertAcceptedSnapshot(
    comptime entity_defs: anytype,
    comptime type_mappings: anytype,
    comptime accepted_snapshot: []const u8,
) void {
    const current = createSchemaSnapshot(entity_defs, type_mappings);
    if (!eql(current, accepted_snapshot))
        @compileError("PostgreSQL schema differs from db/schema.snapshot.json; run 'zig build migration -Dname=<name>'");
}

pub const SnapshotError = error{
    UnsupportedSnapshotVersion,
    UnsupportedDialect,
};

pub fn parseSnapshot(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(Snapshot) {
    const parsed = try std.json.parseFromSlice(Snapshot, allocator, bytes, .{});
    errdefer parsed.deinit();
    if (parsed.value.format_version != snapshot_format_version)
        return error.UnsupportedSnapshotVersion;
    if (!eql(parsed.value.dialect, dialect))
        return error.UnsupportedDialect;
    return parsed;
}

pub const DraftOptions = struct {
    revision: u32,
    name: []const u8,
};

pub const Draft = struct {
    sql: []u8,
    blocker_count: usize,

    pub fn deinit(self: Draft, allocator: std.mem.Allocator) void {
        allocator.free(self.sql);
    }
};

/// Machine-readable classification of a structural difference. Consumers can
/// build their own UI or policy on top of this list without parsing the SQL
/// draft or its comments.
pub const ChangeKind = enum {
    table_added,
    table_removed,
    column_added_nullable,
    column_added_not_null,
    column_removed,
    column_order_changed,
    sql_type_changed,
    nullability_relaxed,
    nullability_tightened,
    domain_type_changed,
    primary_key_changed,
    unique_key_added,
    unique_key_removed_or_changed,
    foreign_key_added,
    foreign_key_removed_or_changed,
};

pub const ChangeSafety = enum {
    automatic,
    blocker,
    metadata_only,
};

pub const Change = struct {
    kind: ChangeKind,
    safety: ChangeSafety,
    table_name: []u8,
    object_name: []u8,
};

pub const SchemaDiff = struct {
    allocator: std.mem.Allocator,
    changes: []Change,

    pub fn deinit(self: SchemaDiff) void {
        for (self.changes) |change| {
            self.allocator.free(change.table_name);
            self.allocator.free(change.object_name);
        }
        self.allocator.free(self.changes);
    }
};

fn findTable(snapshot: Snapshot, name: []const u8) ?*const Table {
    for (snapshot.tables) |*table| if (eql(table.name, name)) return table;
    return null;
}

fn findColumn(table: Table, name: []const u8) ?*const Column {
    for (table.columns) |*column| if (eql(column.name, name)) return column;
    return null;
}

fn findKey(keys: []const Key, name: []const u8) ?*const Key {
    for (keys) |*key| if (eql(key.name, name)) return key;
    return null;
}

fn findForeignKey(keys: []const ForeignKey, name: []const u8) ?*const ForeignKey {
    for (keys) |*key| if (eql(key.name, name)) return key;
    return null;
}

fn namesEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!eql(left, right)) return false;
    return true;
}

fn keysEqual(a: Key, b: Key) bool {
    return eql(a.name, b.name) and namesEqual(a.columns, b.columns);
}

fn foreignKeysEqual(a: ForeignKey, b: ForeignKey) bool {
    return eql(a.name, b.name) and
        eql(a.target_table, b.target_table) and
        namesEqual(a.columns, b.columns) and
        namesEqual(a.target_columns, b.target_columns);
}

fn appendChange(
    changes: *std.ArrayList(Change),
    allocator: std.mem.Allocator,
    kind: ChangeKind,
    safety: ChangeSafety,
    table_name: []const u8,
    object_name: []const u8,
) !void {
    const owned_table = try allocator.dupe(u8, table_name);
    errdefer allocator.free(owned_table);
    const owned_object = try allocator.dupe(u8, object_name);
    errdefer allocator.free(owned_object);
    try changes.append(allocator, .{
        .kind = kind,
        .safety = safety,
        .table_name = owned_table,
        .object_name = owned_object,
    });
}

/// Parses two snapshots and returns every PostgreSQL-visible structural
/// difference in deterministic table/object order.
pub fn diffSnapshots(
    allocator: std.mem.Allocator,
    previous_snapshot: []const u8,
    current_snapshot: []const u8,
) !SchemaDiff {
    var previous = try parseSnapshot(allocator, previous_snapshot);
    defer previous.deinit();
    var current = try parseSnapshot(allocator, current_snapshot);
    defer current.deinit();

    var changes: std.ArrayList(Change) = .empty;
    errdefer {
        for (changes.items) |change| {
            allocator.free(change.table_name);
            allocator.free(change.object_name);
        }
        changes.deinit(allocator);
    }

    for (previous.value.tables) |old_table| {
        const new_table = findTable(current.value, old_table.name) orelse {
            try appendChange(&changes, allocator, .table_removed, .blocker, old_table.name, old_table.name);
            continue;
        };

        if (!keysEqual(old_table.primary_key, new_table.primary_key))
            try appendChange(&changes, allocator, .primary_key_changed, .blocker, old_table.name, old_table.primary_key.name);

        for (old_table.unique_keys) |old_key| {
            const new_key = findKey(new_table.unique_keys, old_key.name);
            if (new_key == null or !keysEqual(old_key, new_key.?.*))
                try appendChange(&changes, allocator, .unique_key_removed_or_changed, .blocker, old_table.name, old_key.name);
        }
        for (old_table.foreign_keys) |old_key| {
            const new_key = findForeignKey(new_table.foreign_keys, old_key.name);
            if (new_key == null or !foreignKeysEqual(old_key, new_key.?.*))
                try appendChange(&changes, allocator, .foreign_key_removed_or_changed, .blocker, old_table.name, old_key.name);
        }

        if (columnLayoutRequiresRebuild(old_table, new_table.*))
            try appendChange(&changes, allocator, .column_order_changed, .blocker, old_table.name, old_table.name);

        for (old_table.columns) |old_column| {
            const new_column = findColumn(new_table.*, old_column.name) orelse {
                try appendChange(&changes, allocator, .column_removed, .blocker, old_table.name, old_column.name);
                continue;
            };
            if (!eql(old_column.sql_type, new_column.sql_type))
                try appendChange(&changes, allocator, .sql_type_changed, .blocker, old_table.name, old_column.name);
            if (old_column.nullable and !new_column.nullable)
                try appendChange(&changes, allocator, .nullability_tightened, .blocker, old_table.name, old_column.name);
            if (!old_column.nullable and new_column.nullable)
                try appendChange(&changes, allocator, .nullability_relaxed, .automatic, old_table.name, old_column.name);
            if (!eql(old_column.domain_type, new_column.domain_type))
                try appendChange(&changes, allocator, .domain_type_changed, .metadata_only, old_table.name, old_column.name);
        }

        for (new_table.columns) |new_column| {
            if (findColumn(old_table, new_column.name) == null)
                try appendChange(
                    &changes,
                    allocator,
                    if (new_column.nullable) .column_added_nullable else .column_added_not_null,
                    if (new_column.nullable) .automatic else .blocker,
                    new_table.name,
                    new_column.name,
                );
        }
        for (new_table.unique_keys) |new_key| {
            if (findKey(old_table.unique_keys, new_key.name) == null)
                try appendChange(&changes, allocator, .unique_key_added, .automatic, new_table.name, new_key.name);
        }
        for (new_table.foreign_keys) |new_key| {
            if (findForeignKey(old_table.foreign_keys, new_key.name) == null)
                try appendChange(&changes, allocator, .foreign_key_added, .automatic, new_table.name, new_key.name);
        }
    }

    for (current.value.tables) |new_table| {
        if (findTable(previous.value, new_table.name) == null)
            try appendChange(&changes, allocator, .table_added, .automatic, new_table.name, new_table.name);
    }

    return .{ .allocator = allocator, .changes = try changes.toOwnedSlice(allocator) };
}

fn appendQuoted(out: *std.ArrayList(u8), allocator: std.mem.Allocator, identifier: []const u8) !void {
    try out.append(allocator, '"');
    for (identifier) |byte| {
        try out.append(allocator, byte);
        if (byte == '"') try out.append(allocator, '"');
    }
    try out.append(allocator, '"');
}

fn appendNameList(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    names: []const []const u8,
) !void {
    for (names, 0..) |name, index| {
        if (index != 0) try out.appendSlice(allocator, ", ");
        try appendQuoted(out, allocator, name);
    }
}

fn appendTableColumn(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    column: Column,
) !void {
    try appendQuoted(out, allocator, column.name);
    try out.print(allocator, " {s}{s}", .{ column.sql_type, if (column.nullable) "" else " NOT NULL" });
}

fn appendAddKey(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    table_name: []const u8,
    kind: []const u8,
    key: Key,
) !void {
    try out.appendSlice(allocator, "ALTER TABLE ");
    try appendQuoted(out, allocator, table_name);
    try out.appendSlice(allocator, " ADD CONSTRAINT ");
    try appendQuoted(out, allocator, key.name);
    try out.print(allocator, " {s} (", .{kind});
    try appendNameList(out, allocator, key.columns);
    try out.appendSlice(allocator, ");\n");
}

fn appendAddForeignKey(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    table_name: []const u8,
    key: ForeignKey,
) !void {
    try out.appendSlice(allocator, "ALTER TABLE ");
    try appendQuoted(out, allocator, table_name);
    try out.appendSlice(allocator, " ADD CONSTRAINT ");
    try appendQuoted(out, allocator, key.name);
    try out.appendSlice(allocator, " FOREIGN KEY (");
    try appendNameList(out, allocator, key.columns);
    try out.appendSlice(allocator, ") REFERENCES ");
    try appendQuoted(out, allocator, key.target_table);
    try out.appendSlice(allocator, " (");
    try appendNameList(out, allocator, key.target_columns);
    try out.appendSlice(allocator, ");\n");
}

fn appendBlocker(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    blocker_count: *usize,
    comptime format: []const u8,
    args: anytype,
) !void {
    blocker_count.* += 1;
    try out.appendSlice(allocator, "-- ZIGMA-BLOCKER: ");
    try out.print(allocator, format, args);
    try out.appendSlice(allocator, "\n");
}

fn appendCreateTable(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    table: Table,
) !void {
    try out.appendSlice(allocator, "CREATE TABLE ");
    try appendQuoted(out, allocator, table.name);
    try out.appendSlice(allocator, " (\n");
    for (table.columns, 0..) |column, index| {
        try out.appendSlice(allocator, "    ");
        try appendTableColumn(out, allocator, column);
        try out.appendSlice(allocator, ",\n");
        _ = index;
    }
    try out.appendSlice(allocator, "    CONSTRAINT ");
    try appendQuoted(out, allocator, table.primary_key.name);
    try out.appendSlice(allocator, " PRIMARY KEY (");
    try appendNameList(out, allocator, table.primary_key.columns);
    try out.append(allocator, ')');
    for (table.unique_keys) |key| {
        try out.appendSlice(allocator, ",\n    CONSTRAINT ");
        try appendQuoted(out, allocator, key.name);
        try out.appendSlice(allocator, " UNIQUE (");
        try appendNameList(out, allocator, key.columns);
        try out.append(allocator, ')');
    }
    try out.appendSlice(allocator, "\n);\n");
}

pub fn snapshotDigest(bytes: []const u8) [64]u8 {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn draftDigestMatches(draft_sql: []const u8, marker: []const u8, snapshot: []const u8) bool {
    const start = (std.mem.indexOf(u8, draft_sql, marker) orelse return false) + marker.len;
    if (draft_sql.len < start + 64) return false;
    const digest = snapshotDigest(snapshot);
    return std.mem.eql(u8, draft_sql[start .. start + 64], &digest);
}

/// True only when both immutable endpoints recorded in a draft still match
/// the accepted and desired snapshots supplied by the caller.
pub fn draftMatchesSnapshots(
    draft_sql: []const u8,
    accepted_snapshot: []const u8,
    desired_snapshot: []const u8,
) bool {
    return draftDigestMatches(draft_sql, "from-sha256=", accepted_snapshot) and
        draftDigestMatches(draft_sql, "to-sha256=", desired_snapshot);
}

pub fn draftHasBlockers(draft_sql: []const u8) bool {
    return std.mem.indexOf(u8, draft_sql, blocker_marker) != null;
}

fn commonColumnOrderChanged(before: Table, after: Table) bool {
    var last_after_index: ?usize = null;
    for (before.columns) |old_column| {
        for (after.columns, 0..) |new_column, new_index| {
            if (!eql(old_column.name, new_column.name)) continue;
            if (last_after_index) |last| if (new_index < last) return true;
            last_after_index = new_index;
            break;
        }
    }
    return false;
}

fn newColumnsAreSuffix(before: Table, after: Table) bool {
    var saw_new = false;
    for (after.columns) |column| {
        if (findColumn(before, column.name) == null) {
            saw_new = true;
        } else if (saw_new) {
            return false;
        }
    }
    return true;
}

fn columnLayoutRequiresRebuild(before: Table, after: Table) bool {
    return commonColumnOrderChanged(before, after) or !newColumnsAreSuffix(before, after);
}

/// Produces one Liquibase formatted-SQL draft. Blockers are deliberately
/// comments and drafts are expected to live outside the accepted changelog
/// directory until a developer resolves them and catalog verification passes.
pub fn createMigrationDraft(
    allocator: std.mem.Allocator,
    previous_snapshot: []const u8,
    current_snapshot: []const u8,
    options: DraftOptions,
) !Draft {
    var previous = try parseSnapshot(allocator, previous_snapshot);
    defer previous.deinit();
    var current = try parseSnapshot(allocator, current_snapshot);
    defer current.deinit();

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var blockers: usize = 0;
    var statement_count: usize = 0;
    const from_hash = snapshotDigest(previous_snapshot);
    const to_hash = snapshotDigest(current_snapshot);

    try out.appendSlice(allocator, "--liquibase formatted sql\n");
    try out.print(allocator, "--changeset zigma:{d:0>6}_{s}\n", .{ options.revision, options.name });
    try out.print(allocator, "--comment: generated by Zigma; from-sha256={s}; to-sha256={s}\n\n", .{ &from_hash, &to_hash });

    // Destructive constraint changes must be resolved before their columns.
    for (previous.value.tables) |old_table| {
        const new_table = findTable(current.value, old_table.name) orelse continue;
        if (!keysEqual(old_table.primary_key, new_table.primary_key))
            try appendBlocker(&out, allocator, &blockers, "primary key of table '{s}' changed; write explicit DROP/ADD CONSTRAINT SQL", .{old_table.name});

        for (old_table.unique_keys) |old_key| {
            const new_key = findKey(new_table.unique_keys, old_key.name);
            if (new_key == null or !keysEqual(old_key, new_key.?.*))
                try appendBlocker(&out, allocator, &blockers, "unique constraint '{s}' on table '{s}' was removed or changed; approve its removal explicitly", .{ old_key.name, old_table.name });
        }
        for (old_table.foreign_keys) |old_key| {
            const new_key = findForeignKey(new_table.foreign_keys, old_key.name);
            if (new_key == null or !foreignKeysEqual(old_key, new_key.?.*))
                try appendBlocker(&out, allocator, &blockers, "foreign key '{s}' on table '{s}' was removed or changed; approve its removal explicitly", .{ old_key.name, old_table.name });
        }
    }

    for (previous.value.tables) |old_table| {
        if (findTable(current.value, old_table.name) == null)
            try appendBlocker(&out, allocator, &blockers, "table '{s}' was removed; decide whether this is DROP TABLE or a rename", .{old_table.name});
    }

    // Create new tables first without FKs; FKs are added after all tables exist.
    for (current.value.tables) |new_table| {
        if (findTable(previous.value, new_table.name) == null) {
            try appendCreateTable(&out, allocator, new_table);
            try out.append(allocator, '\n');
            statement_count += 1;
        }
    }

    for (current.value.tables) |new_table| {
        const old_table = findTable(previous.value, new_table.name) orelse continue;
        const layout_requires_rebuild = columnLayoutRequiresRebuild(old_table.*, new_table);
        if (layout_requires_rebuild)
            try appendBlocker(&out, allocator, &blockers, "existing columns of table '{s}' were reordered; PostgreSQL requires an explicit table rebuild", .{new_table.name});

        for (old_table.columns) |old_column| {
            if (findColumn(new_table, old_column.name) == null)
                try appendBlocker(&out, allocator, &blockers, "column '{s}.{s}' was removed; decide whether this is DROP COLUMN or a rename", .{ new_table.name, old_column.name });
        }

        for (new_table.columns) |new_column| {
            const old_column = findColumn(old_table.*, new_column.name) orelse {
                if (layout_requires_rebuild) {
                    // ADD COLUMN always appends in PostgreSQL, so emitting it
                    // here could never produce the desired catalog order.
                } else if (!new_column.nullable) {
                    try appendBlocker(&out, allocator, &blockers, "new column '{s}.{s}' is NOT NULL; add it, backfill existing rows, then set NOT NULL explicitly", .{ new_table.name, new_column.name });
                } else {
                    try out.appendSlice(allocator, "ALTER TABLE ");
                    try appendQuoted(&out, allocator, new_table.name);
                    try out.appendSlice(allocator, " ADD COLUMN ");
                    try appendTableColumn(&out, allocator, new_column);
                    try out.appendSlice(allocator, ";\n\n");
                    statement_count += 1;
                }
                continue;
            };

            if (!eql(old_column.sql_type, new_column.sql_type))
                try appendBlocker(&out, allocator, &blockers, "column '{s}.{s}' changed SQL type from '{s}' to '{s}'; provide an explicit USING expression", .{ new_table.name, new_column.name, old_column.sql_type, new_column.sql_type });
            if (old_column.nullable and !new_column.nullable)
                try appendBlocker(&out, allocator, &blockers, "column '{s}.{s}' became NOT NULL; provide validation/backfill SQL first", .{ new_table.name, new_column.name });
            if (!old_column.nullable and new_column.nullable) {
                try out.appendSlice(allocator, "ALTER TABLE ");
                try appendQuoted(&out, allocator, new_table.name);
                try out.appendSlice(allocator, " ALTER COLUMN ");
                try appendQuoted(&out, allocator, new_column.name);
                try out.appendSlice(allocator, " DROP NOT NULL;\n\n");
                statement_count += 1;
            }
            if (!eql(old_column.domain_type, new_column.domain_type) and
                eql(old_column.sql_type, new_column.sql_type) and
                old_column.nullable == new_column.nullable)
            {
                try out.print(allocator, "-- Zigma domain type metadata changed for {s}.{s}: {s} -> {s}\n", .{ new_table.name, new_column.name, old_column.domain_type, new_column.domain_type });
            }
        }
    }

    for (current.value.tables) |new_table| {
        const old_table = findTable(previous.value, new_table.name);
        if (old_table) |old| {
            if (!keysEqual(old.primary_key, new_table.primary_key)) {
                // The blocker above owns the whole replacement; do not emit a
                // partial ADD that could conflict with the old constraint.
            }
            for (new_table.unique_keys) |new_key| {
                const old_key = findKey(old.unique_keys, new_key.name);
                if (old_key == null) {
                    try appendAddKey(&out, allocator, new_table.name, "UNIQUE", new_key);
                    try out.append(allocator, '\n');
                    statement_count += 1;
                }
            }
            for (new_table.foreign_keys) |new_key| {
                const old_key = findForeignKey(old.foreign_keys, new_key.name);
                if (old_key == null) {
                    try appendAddForeignKey(&out, allocator, new_table.name, new_key);
                    try out.append(allocator, '\n');
                    statement_count += 1;
                }
            }
        } else {
            for (new_table.foreign_keys) |new_key| {
                try appendAddForeignKey(&out, allocator, new_table.name, new_key);
                try out.append(allocator, '\n');
                statement_count += 1;
            }
        }
    }

    if (statement_count == 0 and blockers == 0)
        try out.appendSlice(allocator, "SELECT 1; -- schema metadata-only change\n");

    return .{
        .sql = try out.toOwnedSlice(allocator),
        .blocker_count = blockers,
    };
}
