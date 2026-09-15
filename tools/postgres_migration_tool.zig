//! Flujo del repositorio para snapshots y archivos de drafts de migraciones Liquibase.

const std = @import("std");
const postgres = @import("aida_postgres");
const migrations = @import("zigma_postgres_migrations");

// Las rutas relativas al repositorio son una política fija de esta herramienta.
// Los módulos de aplicación generados no dependen de esta estructura de directorios.
const snapshot_path = "db/schema.snapshot.json";
const root_changelog_path = "db/changelog-root.yaml";
const changes_path = "db/changes";
const drafts_path = "db/drafts";
const max_file_size = 16 * 1024 * 1024;

// includeAll delega el orden al prefijo de seis dígitos del nombre de archivo.
// La tabla de historial de Liquibase registra qué archivos inmutables ya se ejecutaron.
const root_changelog =
    \\databaseChangeLog:
    \\  - includeAll:
    \\      path: changes
    \\      relativeToChangelogFile: true
;

const ToolError = error{
    InvalidCommand,
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
    // Parsea un conjunto acotado de comandos. Los pasos del build invocan este mismo
    // ejecutable y mantienen el manejo de archivos fuera del modelo puro de migraciones.
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
        const name = args.next();
        if (args.next() != null) return usage(error.InvalidCommand);
        try createDraft(init.gpa, init.io, name);
    } else if (std.mem.eql(u8, command, "accept-files")) {
        try acceptFiles(init.gpa, init.io);
    } else {
        return usage(error.InvalidCommand);
    }
}

fn usage(err: ToolError) ToolError {
    // Devuelve el error tipado original después de imprimir la ayuda, para que
    // los scripts reciban una salida no nula y distingan el uso incorrecto del éxito.
    std.debug.print(
        "usage: postgres-migration-tool <print-snapshot|init|check|draft [NAME]|accept-files>\n",
        .{},
    );
    return err;
}

fn fileExists(io: std.Io, path: []const u8) bool {
    // Acá solo importa si existe; los errores detallados de acceso
    // se informan después, al leer o escribir efectivamente.
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn initialize(io: std.Io) !void {
    // La inicialización se hace una sola vez. Rechazar un snapshot existente
    // evita reemplazar en silencio un historial ya aceptado.
    const cwd = std.Io.Dir.cwd();
    if (fileExists(io, snapshot_path)) return error.AlreadyInitialized;
    try cwd.createDirPath(io, changes_path);
    try cwd.createDirPath(io, drafts_path);
    try cwd.writeFile(io, .{ .sub_path = root_changelog_path, .data = root_changelog });

    // El baseline es SQL normal con formato Liquibase, pero omite IF NOT EXISTS
    // para que una base no vacía o incompatible falle de forma visible.
    const baseline = "--liquibase formatted sql\n" ++
        "--changeset zigma:000001_baseline\n" ++
        "--comment: initial schema generated from the Zigma desired state\n\n" ++
        postgres.baseline_ddl;
    try cwd.writeFile(io, .{ .sub_path = changes_path ++ "/000001_baseline.sql", .data = baseline });
    try cwd.writeFile(io, .{ .sub_path = snapshot_path, .data = postgres.schema_snapshot });
    std.debug.print("Initialized Liquibase history at revision 000001\n", .{});
}

fn readSnapshot(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    // Un límite fijo impide que un archivo corrupto del repositorio consuma
    // memoria ilimitada en un proceso de desarrollo o de build.
    if (!fileExists(io, snapshot_path)) return error.NotInitialized;
    return std.Io.Dir.cwd().readFileAlloc(io, snapshot_path, allocator, .limited(max_file_size));
}

fn check(allocator: std.mem.Allocator, io: std.Io) !void {
    // La igualdad de bytes es válida porque los snapshots son canónicos y deterministas.
    const accepted = try readSnapshot(allocator, io);
    defer allocator.free(accepted);
    if (std.mem.eql(u8, accepted, postgres.schema_snapshot)) {
        std.debug.print("PostgreSQL schema snapshot is current\n", .{});
        return;
    }

    const revision = try nextRevision(io);
    const name = try migrations.inferMigrationName(allocator, accepted, postgres.schema_snapshot);
    defer allocator.free(name);
    // Genera una vista previa solo para explicar la diferencia. `check` nunca
    // escribe un draft ni avanza el historial como efecto de un build normal.
    const preview = try migrations.createMigrationDraft(allocator, accepted, postgres.schema_snapshot, .{
        .revision = revision,
        .name = name,
    });
    defer preview.deinit(allocator);
    std.debug.print(
        "PostgreSQL schema differs from {s}:\n\n{s}\nRun 'zig build migration' or override the name with '-Dname=<name>'.\n",
        .{ snapshot_path, preview.sql },
    );
    return error.SchemaChanged;
}

fn validName(name: []const u8) bool {
    // Limita el sufijo elegido por la persona a nombres de archivo portables e IDs seguros de
    // Liquibase.
    if (name.len == 0) return false;
    for (name) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn resolveDraftName(
    allocator: std.mem.Allocator,
    accepted_snapshot: []const u8,
    desired_snapshot: []const u8,
    override: ?[]const u8,
) ![]u8 {
    if (override) |name| {
        if (!validName(name)) return error.InvalidName;
        return allocator.dupe(u8, name);
    }
    return migrations.inferMigrationName(allocator, accepted_snapshot, desired_snapshot);
}

fn draftFilename(allocator: std.mem.Allocator, revision: u32, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d:0>6}_{s}.sql", .{ revision, name });
}

fn nextRevision(io: std.Io) !u32 {
    // Recorre solo los cambios aceptados. Exactamente seis dígitos iniciales definen
    // el orden; los archivos ajenos se ignoran para no convertirlos accidentalmente en
    // revisiones.
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
    // Un único draft pendiente hace inequívoca la relación entre snapshots origen
    // y destino. Quien llama debe liberar el nombre de archivo devuelto.
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

fn createDraft(allocator: std.mem.Allocator, io: std.Io, name_override: ?[]const u8) !void {
    // La generación del draft lee el historial aceptado y el estado deseado actual
    // compilado, pero deja el snapshot aceptado sin cambios.
    if (name_override) |name| if (!validName(name)) return error.InvalidName;
    if (try onlyDraft(allocator, io)) |existing| {
        allocator.free(existing);
        return error.DraftAlreadyExists;
    }

    const accepted = try readSnapshot(allocator, io);
    defer allocator.free(accepted);
    if (std.mem.eql(u8, accepted, postgres.schema_snapshot)) return error.SchemaUnchanged;

    const name = try resolveDraftName(allocator, accepted, postgres.schema_snapshot, name_override);
    defer allocator.free(name);
    const revision = try nextRevision(io);
    const draft = try migrations.createMigrationDraft(allocator, accepted, postgres.schema_snapshot, .{
        .revision = revision,
        .name = name,
    });
    defer draft.deinit(allocator);

    const filename = try draftFilename(allocator, revision, name);
    defer allocator.free(filename);
    const path = try std.fs.path.join(allocator, &.{ drafts_path, filename });
    defer allocator.free(path);
    // La creación exclusiva evita sobrescribir ediciones manuales o una revisión
    // de otra rama aparecida después del recorrido inicial del directorio.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = draft.sql, .flags = .{ .exclusive = true } });
    std.debug.print("Created {s} with {d} blocker(s)\n", .{ path, draft.blocker_count });
}

fn writeAcceptedSnapshotAtomically(io: std.Io) !void {
    // Escribir y reemplazar hace que se vea el snapshot anterior completo o el
    // nuevo completo, nunca un archivo JSON escrito parcialmente.
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(io, snapshot_path, .{ .replace = true });
    defer atomic_file.deinit(io);
    try atomic_file.file.writeStreamingAll(io, postgres.schema_snapshot);
    try atomic_file.replace(io);
}

fn acceptFiles(allocator: std.mem.Allocator, io: std.Io) !void {
    // La aceptación es la parte del flujo que modifica el filesystem. Primero el
    // build reproduce y valida en una base descartable; después llama a este comando.
    const filename = (try onlyDraft(allocator, io)) orelse return error.DraftMissing;
    defer allocator.free(filename);
    const draft_path = try std.fs.path.join(allocator, &.{ drafts_path, filename });
    defer allocator.free(draft_path);
    const contents = try std.Io.Dir.cwd().readFileAlloc(io, draft_path, allocator, .limited(max_file_size));
    defer allocator.free(contents);
    // Un comentario de bloqueo indica que hay que detenerse: el desarrollador
    // debe reemplazarlo por SQL revisado para cambios destructivos o ambiguos.
    if (migrations.draftHasBlockers(contents))
        return error.DraftHasBlockers;
    const accepted_snapshot = try readSnapshot(allocator, io);
    defer allocator.free(accepted_snapshot);
    // Los hashes incorporados impiden aceptar un draft generado desde un origen
    // o destino anterior después de que cambiaron las entidades o el historial.
    if (!migrations.draftMatchesSnapshots(contents, accepted_snapshot, postgres.schema_snapshot))
        return error.StaleDraft;

    const accepted_path = try std.fs.path.join(allocator, &.{ changes_path, filename });
    defer allocator.free(accepted_path);
    // Primero mueve el SQL revisado al historial inmutable. Si falla el avance del
    // snapshot, errdefer restaura el draft para mantener ambos artefactos asociados.
    try std.Io.Dir.renamePreserve(std.Io.Dir.cwd(), draft_path, std.Io.Dir.cwd(), accepted_path, io);
    errdefer std.Io.Dir.renamePreserve(std.Io.Dir.cwd(), accepted_path, std.Io.Dir.cwd(), draft_path, io) catch {};
    try writeAcceptedSnapshotAtomically(io);
    std.debug.print("Accepted {s} and advanced {s}\n", .{ accepted_path, snapshot_path });
}

test "draft name resolution preserves valid overrides and infers an absent name" {
    const before =
        \\{"format_version":1,"dialect":"postgresql","tables":[]}
    ;
    const after =
        \\{"format_version":1,"dialect":"postgresql","tables":[{"name":"things","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false}],"primary_key":{"name":"pk_things","columns":["id"]},"unique_keys":[],"foreign_keys":[]}]}
    ;

    const automatic = try resolveDraftName(std.testing.allocator, before, after, null);
    defer std.testing.allocator.free(automatic);
    try std.testing.expectEqualStrings("create_table_things", automatic);

    const manual = try resolveDraftName(std.testing.allocator, before, after, "Rename_Things");
    defer std.testing.allocator.free(manual);
    try std.testing.expectEqualStrings("Rename_Things", manual);

    try std.testing.expectError(
        error.InvalidName,
        resolveDraftName(std.testing.allocator, before, after, "invalid-name"),
    );
}

test "resolved migration name is used in the draft filename and changeset metadata" {
    const before =
        \\{"format_version":1,"dialect":"postgresql","tables":[]}
    ;
    const after =
        \\{"format_version":1,"dialect":"postgresql","tables":[{"name":"things","columns":[{"name":"id","domain_type":"integer","sql_type":"BIGINT","nullable":false}],"primary_key":{"name":"pk_things","columns":["id"]},"unique_keys":[],"foreign_keys":[]}]}
    ;
    const name = try resolveDraftName(std.testing.allocator, before, after, null);
    defer std.testing.allocator.free(name);
    const filename = try draftFilename(std.testing.allocator, 2, name);
    defer std.testing.allocator.free(filename);
    try std.testing.expectEqualStrings("000002_create_table_things.sql", filename);

    const draft = try migrations.createMigrationDraft(std.testing.allocator, before, after, .{
        .revision = 2,
        .name = name,
    });
    defer draft.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        draft.sql,
        "--changeset zigma:000002_create_table_things",
    ) != null);
}
