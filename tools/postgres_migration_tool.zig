//! Repository workflow for snapshots and Liquibase migration draft files.

const std = @import("std");
const postgres = @import("aida_postgres");
const migrations = @import("zigma_postgres_migrations");

const snapshot_path = "db/schema.snapshot.json";
const root_changelog_path = "db/changelog-root.yaml";
const changes_path = "db/changes";
const drafts_path = "db/drafts";
const max_file_size = 16 * 1024 * 1024;

const root_changelog =
    \\databaseChangeLog:
    \\  - includeAll:
    \\      path: changes
    \\      relativeToChangelogFile: true
;

const ToolError = error{
    InvalidCommand,
    MissingName,
    InvalidName,
    AlreadyInitialized,
    NotInitialized,
    SchemaUnchanged,
    SchemaChanged,
    DraftAlreadyExists,
    DraftMissing,
    DraftHasBlockers,
    StaleDraft,
    RevisionExhausted,
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const command = args.next() orelse return usage(error.InvalidCommand);

    if (std.mem.eql(u8, command, "print-snapshot")) {
        std.debug.print("{s}", .{postgres.schema_snapshot});
    } else if (std.mem.eql(u8, command, "init")) {
        try initialize(init.io);
    } else if (std.mem.eql(u8, command, "check")) {
        try check(init.gpa, init.io);
    } else if (std.mem.eql(u8, command, "draft")) {
        const name = args.next() orelse return usage(error.MissingName);
        try createDraft(init.gpa, init.io, name);
    } else if (std.mem.eql(u8, command, "accept-files")) {
        try acceptFiles(init.gpa, init.io);
    } else {
        return usage(error.InvalidCommand);
    }
}

fn usage(err: ToolError) ToolError {
    std.debug.print(
        "usage: postgres-migration-tool <print-snapshot|init|check|draft NAME|accept-files>\n",
        .{},
    );
    return err;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn initialize(io: std.Io) !void {
    const cwd = std.Io.Dir.cwd();
    if (fileExists(io, snapshot_path)) return error.AlreadyInitialized;
    try cwd.createDirPath(io, changes_path);
    try cwd.createDirPath(io, drafts_path);
    try cwd.writeFile(io, .{ .sub_path = root_changelog_path, .data = root_changelog });

    const baseline = "--liquibase formatted sql\n" ++
        "--changeset zigma:000001_baseline\n" ++
        "--comment: initial schema generated from the Zigma desired state\n\n" ++
        postgres.baseline_ddl;
    try cwd.writeFile(io, .{ .sub_path = changes_path ++ "/000001_baseline.sql", .data = baseline });
    try cwd.writeFile(io, .{ .sub_path = snapshot_path, .data = postgres.schema_snapshot });
    std.debug.print("Initialized Liquibase history at revision 000001\n", .{});
}

fn readSnapshot(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    if (!fileExists(io, snapshot_path)) return error.NotInitialized;
    return std.Io.Dir.cwd().readFileAlloc(io, snapshot_path, allocator, .limited(max_file_size));
}

fn check(allocator: std.mem.Allocator, io: std.Io) !void {
    const accepted = try readSnapshot(allocator, io);
    defer allocator.free(accepted);
    if (std.mem.eql(u8, accepted, postgres.schema_snapshot)) {
        std.debug.print("PostgreSQL schema snapshot is current\n", .{});
        return;
    }

    const revision = try nextRevision(io);
    const preview = try migrations.createMigrationDraft(allocator, accepted, postgres.schema_snapshot, .{
        .revision = revision,
        .name = "pending",
    });
    defer preview.deinit(allocator);
    std.debug.print("PostgreSQL schema differs from {s}:\n\n{s}\nRun 'zig build migration -Dname=<name>'.\n", .{ snapshot_path, preview.sql });
    return error.SchemaChanged;
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn nextRevision(io: std.Io) !u32 {
    var dir = try std.Io.Dir.cwd().openDir(io, changes_path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var maximum: u32 = 0;
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sql")) continue;
        const separator = std.mem.indexOfScalar(u8, entry.name, '_') orelse continue;
        if (separator != 6) continue;
        const revision = std.fmt.parseInt(u32, entry.name[0..separator], 10) catch continue;
        maximum = @max(maximum, revision);
    }
    if (maximum >= 999_999) return error.RevisionExhausted;
    return maximum + 1;
}

fn onlyDraft(allocator: std.mem.Allocator, io: std.Io) !?[]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, drafts_path, .{ .iterate = true });
    defer dir.close(io);
    var iterator = dir.iterate();
    var result: ?[]u8 = null;
    errdefer if (result) |name| allocator.free(name);
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sql")) continue;
        if (result != null) return error.DraftAlreadyExists;
        result = try allocator.dupe(u8, entry.name);
    }
    return result;
}

fn createDraft(allocator: std.mem.Allocator, io: std.Io, name: []const u8) !void {
    if (!validName(name)) return error.InvalidName;
    if (try onlyDraft(allocator, io)) |existing| {
        allocator.free(existing);
        return error.DraftAlreadyExists;
    }

    const accepted = try readSnapshot(allocator, io);
    defer allocator.free(accepted);
    if (std.mem.eql(u8, accepted, postgres.schema_snapshot)) return error.SchemaUnchanged;

    const revision = try nextRevision(io);
    const draft = try migrations.createMigrationDraft(allocator, accepted, postgres.schema_snapshot, .{
        .revision = revision,
        .name = name,
    });
    defer draft.deinit(allocator);

    const filename = try std.fmt.allocPrint(allocator, "{d:0>6}_{s}.sql", .{ revision, name });
    defer allocator.free(filename);
    const path = try std.fs.path.join(allocator, &.{ drafts_path, filename });
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = draft.sql, .flags = .{ .exclusive = true } });
    std.debug.print("Created {s} with {d} blocker(s)\n", .{ path, draft.blocker_count });
}

fn writeAcceptedSnapshotAtomically(io: std.Io) !void {
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, snapshot_path, .{ .replace = true });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, postgres.schema_snapshot);
    try atomic_file.replace(io);
}

fn acceptFiles(allocator: std.mem.Allocator, io: std.Io) !void {
    const filename = (try onlyDraft(allocator, io)) orelse return error.DraftMissing;
    defer allocator.free(filename);
    const draft_path = try std.fs.path.join(allocator, &.{ drafts_path, filename });
    defer allocator.free(draft_path);
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, draft_path, allocator, .limited(max_file_size));
    defer allocator.free(contents);
    if (migrations.draftHasBlockers(contents))
        return error.DraftHasBlockers;
    const accepted_snapshot = try readSnapshot(allocator, io);
    defer allocator.free(accepted_snapshot);
    if (!migrations.draftMatchesSnapshots(contents, accepted_snapshot, postgres.schema_snapshot))
        return error.StaleDraft;

    const accepted_path = try std.fs.path.join(allocator, &.{ changes_path, filename });
    defer allocator.free(accepted_path);
    try std.Io.Dir.renamePreserve(std.Io.Dir.cwd(), draft_path, std.Io.Dir.cwd(), accepted_path, io);
    errdefer std.Io.Dir.renamePreserve(std.Io.Dir.cwd(), accepted_path, std.Io.Dir.cwd(), draft_path, io) catch {};
    try writeAcceptedSnapshotAtomically(io);
    std.debug.print("Accepted {s} and advanced {s}\n", .{ accepted_path, snapshot_path });
}
