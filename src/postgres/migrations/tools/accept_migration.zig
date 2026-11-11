//! Reproduce y valida un draft en PostgreSQL descartable antes de aceptar sus archivos.
//! Coordinación nativa para macOS/Linux; Docker y Liquibase siguen siendo procesos externos.
const std = @import("std");
const Io = std.Io;
const posix = std.posix;

var interrupted: std.atomic.Value(bool) = .init(false);

fn onSignal(_: posix.SIG) callconv(.c) void {
    interrupted.store(true, .monotonic);
}

pub fn main(init: std.process.Init) void {
    const action: posix.Sigaction = .{
        .handler = .{ .handler = onSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    posix.sigaction(.INT, &action, null);
    posix.sigaction(.TERM, &action, null);
    const code: u8 = if (accept(init)) |_| 0 else |err| blk: {
        std.debug.print("Migration acceptance failed: {t}\n", .{err});
        break :blk 1;
    };
    // accept ya terminó sus defer, incluso ante interrupciones.
    std.process.exit(code);
}

fn checkInterrupted() !void {
    if (interrupted.load(.monotonic)) return error.Interrupted;
}

const CommandOptions = struct {
    environment: ?*const std.process.Environ.Map = null,
    stdout: std.process.SpawnOptions.StdIo = .inherit,
    stderr: std.process.SpawnOptions.StdIo = .inherit,
    deadline: ?Io.Timestamp = null,
    cancel_on_interrupt: bool = true,
};

const Command = struct {
    child: std.process.Child,
    done: Io.Event = .unset,
    term: ?std.process.Child.Term = null,

    fn watch(self: *Command, io: Io) void {
        defer self.done.set(io);
        self.term = self.child.wait(io) catch return;
    }

    fn stop(self: *Command, io: Io, group: posix.pid_t, watcher: *Io.Future(void)) void {
        // Liquibase puede tener una JVM descendiente: se cancela todo el grupo.
        posix.kill(-group, .TERM) catch {};
        const deadline = Io.Clock.awake.now(io).addDuration(.fromMilliseconds(500));
        while (Io.Clock.awake.now(io).nanoseconds < deadline.nanoseconds) {
            posix.kill(-group, @fromBackingInt(@intCast(0))) catch break;
            io.sleep(.fromMilliseconds(20), .awake) catch break;
        }
        posix.kill(-group, .KILL) catch {};
        watcher.await(io);
        self.child.kill(io);
    }
};

const Commands = struct {
    io: Io,
    project: Io.Dir,
    environment: *const std.process.Environ.Map,

    fn execute(self: Commands, argv: []const []const u8, opts: CommandOptions) !std.process.Child.Term {
        if (opts.cancel_on_interrupt) try checkInterrupted();
        var command: Command = .{ .child = try std.process.spawn(self.io, .{
            .argv = argv,
            .cwd = .{ .dir = self.project },
            .environ_map = opts.environment orelse self.environment,
            .pgid = 0,
            .stdin = .ignore,
            .stdout = opts.stdout,
            .stderr = opts.stderr,
        }) };
        const group = command.child.id.?;
        var watcher = self.io.concurrent(Command.watch, .{ &command, self.io }) catch |err| {
            posix.kill(-group, .KILL) catch {};
            command.child.kill(self.io);
            return err;
        };
        var joined = false;
        defer if (!joined) command.stop(self.io, group, &watcher);
        while (!command.done.isSet()) {
            if (opts.cancel_on_interrupt) try checkInterrupted();
            if (opts.deadline) |deadline| {
                if (Io.Clock.awake.now(self.io).nanoseconds >= deadline.nanoseconds)
                    return error.CommandTimeout;
            }
            try self.io.sleep(.fromMilliseconds(20), .awake);
        }
        watcher.await(self.io);
        joined = true;
        return command.term orelse {
            command.child.kill(self.io);
            return error.ProcessWaitFailed;
        };
    }

    fn require(self: Commands, argv: []const []const u8, opts: CommandOptions) !void {
        const term = try self.execute(argv, opts);
        if (!term.success()) {
            std.debug.print("{s}: {f}\n", .{ argv[0], term });
            return error.CommandFailed;
        }
    }

    fn removeContainer(self: Commands, name: []const u8) void {
        // La limpieza tiene su propio plazo y continúa aunque llegó SIGINT/SIGTERM.
        self.require(&.{ "docker", "rm", "-f", name }, .{
            .stdout = .ignore,
            .deadline = Io.Clock.awake.now(self.io).addDuration(.fromSeconds(10)),
            .cancel_on_interrupt = false,
        }) catch |err| std.debug.print("Cannot remove disposable container {s}: {t}\n", .{ name, err });
    }
};

fn findDraft(allocator: std.mem.Allocator, io: Io, project: Io.Dir) ![]const u8 {
    var directory = try project.openDir(io, "db/drafts", .{ .iterate = true });
    defer directory.close(io);
    var entries = directory.iterate();
    var name: ?[]const u8 = null;
    while (try entries.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sql")) continue;
        if (name != null) return error.MultipleDrafts;
        name = try allocator.dupe(u8, entry.name);
    }
    const draft = name orelse return error.DraftMissing;
    const sql = try directory.readFileAlloc(io, draft, allocator, .limited(16 * 1024 * 1024));
    if (std.mem.indexOf(u8, sql, "ZIGMA-BLOCKER:") != null) return error.DraftHasBlockers;
    return draft;
}

fn startupDuration(environment: *const std.process.Environ.Map) !Io.Duration {
    const seconds = std.fmt.parseFloat(f64, environment.get("ZIGMA_MIGRATION_STARTUP_TIMEOUT") orelse "120") catch
        return error.InvalidStartupTimeout;
    if (!std.math.isFinite(seconds) or seconds <= 0 or seconds > 86400)
        return error.InvalidStartupTimeout;
    return .{ .nanoseconds = @intFromFloat(seconds * std.time.ns_per_s) };
}

fn accept(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 5) {
        std.debug.print("usage: accept-migration <migration-tool> <validator> <liquibase> <project-root>\n", .{});
        return error.InvalidArguments;
    }
    const startup_timeout = try startupDuration(init.environ_map);
    const project = try Io.Dir.cwd().openDir(io, args[4], .{});
    defer project.close(io);
    const project_root = try project.realPathFileAlloc(io, ".", allocator);
    const draft = try findDraft(allocator, io, project);
    try checkInterrupted();

    // Nombre único para el directorio privado y el contenedor de esta invocación.
    var random: [16]u8 = undefined;
    io.random(&random);
    const name = try std.fmt.allocPrint(allocator, "zigma-migration-{s}", .{std.fmt.bytesToHex(random, .lower)});
    const temporary_root = try Io.Dir.cwd().openDir(io, init.environ_map.get("TMPDIR") orelse "/tmp", .{});
    defer temporary_root.close(io);
    try temporary_root.createDir(io, name, .fromMode(0o700));
    defer temporary_root.deleteTree(io, name) catch |err|
        std.debug.print("Cannot remove temporary directory {s}: {t}\n", .{ name, err });
    const temporary_path = try temporary_root.realPathFileAlloc(io, name, allocator);
    const temporary = try temporary_root.openDir(io, name, .{});
    defer temporary.close(io);

    const commands: Commands = .{ .io = io, .project = project, .environment = init.environ_map };
    // Se registra antes de docker run: también limpia un arranque parcialmente fallido.
    defer commands.removeContainer(name);
    const deadline = Io.Clock.awake.now(io).addDuration(startup_timeout);
    try commands.require(&.{
        "docker",                   "run",                        "--detach", "--rm",                   "--name", name,
        "-e",                       "POSTGRES_PASSWORD=postgres", "-e",       "POSTGRES_DB=zigma_test", "-p",     "127.0.0.1::5432",
        "postgres:18.4-alpine3.24",
    }, .{ .stdout = .ignore, .deadline = deadline });
    // El servidor temporal de inicialización solo escucha por socket; esperar TCP.
    while (true) {
        if (Io.Clock.awake.now(io).nanoseconds >= deadline.nanoseconds) return error.StartupTimeout;
        const term = commands.execute(&.{
            "docker", "exec", name, "pg_isready", "-h", "127.0.0.1", "-U", "postgres", "-d", "zigma_test",
        }, .{ .stdout = .ignore, .stderr = .ignore, .deadline = deadline }) catch |err| switch (err) {
            error.CommandTimeout => return error.StartupTimeout,
            else => return err,
        };
        if (term.success()) break;
        try io.sleep(.fromMilliseconds(100), .awake);
    }

    // Un archivo acotado permite capturar el puerto sin bloquear una tubería de salida.
    const port_file = try temporary.createFile(io, "port.txt", .{});
    defer port_file.close(io);
    try commands.require(&.{ "docker", "port", name, "5432/tcp" }, .{
        .stdout = .{ .file = port_file },
        .deadline = deadline,
    });
    const port_text = std.mem.trim(u8, try temporary.readFileAlloc(io, "port.txt", allocator, .limited(1024)), " \r\n\t");
    const separator = std.mem.lastIndexOfScalar(u8, port_text, ':') orelse return error.InvalidPublishedPort;
    const port = std.fmt.parseInt(u16, port_text[separator + 1 ..], 10) catch return error.InvalidPublishedPort;
    if (port == 0) return error.InvalidPublishedPort;
    try commands.require(&.{
        "docker", "exec",            name, "psql",                 "-U", "postgres", "-d", "zigma_test",
        "-v",     "ON_ERROR_STOP=1", "-c", "CREATE SCHEMA actual",
    }, .{ .stdout = .ignore, .deadline = deadline });

    const draft_path = try std.fmt.allocPrint(allocator, "db/drafts/{s}", .{draft});
    const changelog = try std.fmt.allocPrint(
        allocator,
        "databaseChangeLog:\n  - include:\n      file: db/changelog-root.yaml\n  - include:\n      file: {f}\n",
        .{std.json.fmt(draft_path, .{})},
    );
    try temporary.writeFile(io, .{ .sub_path = "changelog-root.yaml", .data = changelog });

    var liquibase_environment = try init.environ_map.clone(allocator);
    defer liquibase_environment.deinit();
    // Aliases de la aplicación que el CLI Liquibase 5 no reconoce.
    for ([_][]const u8{ "LIQUIBASE_BIN", "LIQUIBASE_CHANGELOG", "LIQUIBASE_URL", "LIQUIBASE_USERNAME", "LIQUIBASE_PASSWORD", "LIQUIBASE_SCHEMA" }) |key|
        _ = liquibase_environment.swapRemove(key);
    try liquibase_environment.put("LIQUIBASE_COMMAND_URL", try std.fmt.allocPrint(allocator, "jdbc:postgresql://127.0.0.1:{d}/zigma_test", .{port}));
    try liquibase_environment.put("LIQUIBASE_COMMAND_USERNAME", "postgres");
    try liquibase_environment.put("LIQUIBASE_COMMAND_PASSWORD", "postgres");
    const search_path = try std.fmt.allocPrint(allocator, "--search-path={s},{s}", .{ temporary_path, project_root });
    try commands.require(&.{ args[3], search_path, "--changelog-file=changelog-root.yaml", "--default-schema-name=actual", "update" }, .{
        .environment = &liquibase_environment,
    });

    var validator_environment = try init.environ_map.clone(allocator);
    defer validator_environment.deinit();
    try validator_environment.put("DATABASE_URL", try std.fmt.allocPrint(allocator, "postgresql://postgres:postgres@127.0.0.1:{d}/zigma_test", .{port}));
    try validator_environment.put("ZIGMA_ACTUAL_SCHEMA", "actual");
    try commands.require(&.{args[2]}, .{ .environment = &validator_environment });

    // La promoción final es breve: una señal posterior a su inicio no debe interrumpir
    // el movimiento del SQL y el reemplazo del snapshot entre sus dos escrituras.
    try checkInterrupted();
    try commands.require(&.{ args[1], "accept-files" }, .{ .cancel_on_interrupt = false });
}
