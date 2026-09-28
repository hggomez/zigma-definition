//! Lanzador local de AIDA: supervisa el backend y sirve el frontend compilado.
//! El build prepara los artefactos; este proceso administra su vida en macOS/Linux.
const std = @import("std");
const Io = std.Io;
const posix = std.posix;

var interrupted: std.atomic.Value(bool) = .init(false);

// El handler solo modifica una bandera: el cierre y la memoria quedan fuera de él.
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
    const code = run(init) catch |err| blk: {
        std.debug.print("No se pudo iniciar AIDA: {t}\n", .{err});
        break :blk @as(u8, 1);
    };
    // run ya ejecutó todos sus defer antes de terminar el proceso.
    std.process.exit(code);
}

fn portFromEnv(env: *const std.process.Environ.Map, name: []const u8, default: u16) !u16 {
    const text = env.get(name) orelse return default;
    const port = std.fmt.parseInt(u16, text, 10) catch return error.InvalidPort;
    if (port == 0) return error.InvalidPort;
    return port;
}

fn pause(io: Io, milliseconds: i64) Io.Cancelable!void {
    try io.sleep(.fromMilliseconds(milliseconds), .awake);
}

const Backend = struct {
    child: std.process.Child,
    done: Io.Event = .unset,
    code: u8 = 1,

    // Solo esta tarea usa Child hasta que termina; done publica también code.
    fn watch(self: *Backend, io: Io) void {
        defer self.done.set(io);
        const term = self.child.wait(io) catch return;
        self.code = switch (term) {
            .exited => |code| if (code == 0) 1 else code,
            else => 1,
        };
    }

    fn stop(self: *Backend, io: Io, group: posix.pid_t, watcher: *Io.Future(void)) void {
        // El grupo incluye procesos de migración que el backend haya iniciado.
        posix.kill(-group, .TERM) catch {};
        const deadline = Io.Clock.awake.now(io).addDuration(.fromSeconds(3));
        while (Io.Clock.awake.now(io).nanoseconds < deadline.nanoseconds) {
            posix.kill(-group, @fromBackingInt(@intCast(0))) catch break;
            pause(io, 50) catch break;
        }
        posix.kill(-group, .KILL) catch {};
        watcher.await(io);
        self.child.kill(io);
    }
};

fn run(init: std.process.Init) !u8 {
    const io = init.io;
    const allocator = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3) {
        std.debug.print("Uso: run-aida <aida-rest-server> <frontend-directory>\n", .{});
        return 1;
    }
    const backend_port = try portFromEnv(init.environ_map, "HTTP_PORT", 8080);
    const frontend_port = try portFromEnv(init.environ_map, "FRONTEND_PORT", 8000);
    if (backend_port == frontend_port) {
        std.debug.print("HTTP_PORT y FRONTEND_PORT deben ser distintos\n", .{});
        return 1;
    }
    const timeout_seconds = try std.fmt.parseFloat(f64, init.environ_map.get("AIDA_STARTUP_TIMEOUT") orelse "120");
    if (!std.math.isFinite(timeout_seconds) or timeout_seconds <= 0 or timeout_seconds > 1e12)
        return error.InvalidStartupTimeout;
    const timeout: Io.Duration = .{ .nanoseconds = @intFromFloat(timeout_seconds * std.time.ns_per_s) };
    const address = init.environ_map.get("HTTP_ADDRESS") orelse "127.0.0.1";
    const host = if (std.mem.eql(u8, address, "0.0.0.0")) "127.0.0.1" else if (std.mem.eql(u8, address, "::")) "::1" else address;
    const backend_address = try Io.net.IpAddress.parse(host, backend_port);
    const api_url = if (std.mem.indexOfScalar(u8, host, ':') != null)
        try std.fmt.allocPrint(allocator, "http://[{s}]:{d}/api", .{ host, backend_port })
    else
        try std.fmt.allocPrint(allocator, "http://{s}:{d}/api", .{ host, backend_port });
    defer allocator.free(api_url);
    const config = try std.fmt.allocPrint(allocator, "globalThis.ZIGMA_API_BASE = {f};\n", .{std.json.fmt(api_url, .{})});
    defer allocator.free(config);

    const directory = try Io.Dir.cwd().openDir(io, args[2], .{});
    defer directory.close(io);
    const index = try directory.openFile(io, "index.html", .{});
    index.close(io);

    if (try probePort(io, backend_address, false)) {
        std.debug.print("El puerto del backend ({d}) ya está ocupado\n", .{backend_port});
        return 1;
    }

    // Reservar este puerto antes de spawn evita migraciones con un frontend ocupado.
    const frontend_address = try Io.net.IpAddress.parse("127.0.0.1", frontend_port);
    var listener = frontend_address.listen(io, .{ .reuse_address = true }) catch |err| {
        std.debug.print("No se pudo reservar el puerto del frontend ({d}): {t}\n", .{ frontend_port, err });
        return 1;
    };
    defer listener.deinit(io);
    if (interrupted.load(.monotonic)) return 0;

    var backend: Backend = .{ .child = try std.process.spawn(io, .{
        .argv = &.{args[1]},
        .environ_map = init.environ_map,
        .pgid = 0,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) };
    const group = backend.child.id.?;
    var watcher = io.concurrent(Backend.watch, .{ &backend, io }) catch |err| {
        posix.kill(-group, .KILL) catch {};
        backend.child.kill(io);
        return err;
    };
    defer backend.stop(io, group, &watcher);

    std.debug.print("Iniciando AIDA con PostgreSQL; esperando migraciones y API...\n", .{});
    const deadline = Io.Clock.awake.now(io).addDuration(timeout);
    while (true) {
        if (interrupted.load(.monotonic)) return 0;
        if (backend.done.isSet()) return backend.code;
        if (Io.Clock.awake.now(io).nanoseconds >= deadline.nanoseconds) return error.StartupTimeout;
        if (try probePort(io, backend_address, true)) break;
        try pause(io, 100);
    }

    var frontend: Frontend = .{ .directory = directory, .config = config };
    var server = try io.concurrent(Frontend.serve, .{ &frontend, io, allocator, &listener });
    defer server.cancel(io) catch {};
    std.debug.print("Frontend: http://127.0.0.1:{d}\nAPI: {s}\nCtrl+C para detener ambos.\n", .{ frontend_port, api_url });
    while (!interrupted.load(.monotonic)) {
        if (backend.done.isSet()) return backend.code;
        if (frontend.done.isSet()) {
            try server.await(io);
            return error.FrontendStopped;
        }
        try pause(io, 100);
    }
    return 0;
}

fn probePort(io: Io, address: Io.net.IpAddress, comptime check_api: bool) !bool {
    // Limita también la lectura: un socket abierto todavía no implica una API lista.
    const Race = Io.Select(union(enum) { probe: bool, timeout: Io.Cancelable!void });
    var buffer: [2]Race.Union = undefined;
    var race = Race.init(io, &buffer);
    defer race.cancelDiscard();
    try race.concurrent(.probe, probeBackend, .{ io, address, check_api });
    try race.concurrent(.timeout, pause, .{ io, 300 });
    return switch (try race.await()) {
        .probe => |ready| ready,
        .timeout => if (check_api) false else error.BackendPortCheckTimeout,
    };
}

fn probeBackend(io: Io, address: Io.net.IpAddress, check_api: bool) bool {
    const stream = address.connect(io, .{ .mode = .stream }) catch return false;
    defer stream.close(io);
    if (!check_api) return true;
    var output: [256]u8 = undefined;
    var writer = stream.writer(io, &output);
    writer.interface.writeAll("OPTIONS /api/ HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n") catch return false;
    writer.interface.flush() catch return false;
    var input: [1024]u8 = undefined;
    var reader = stream.reader(io, &input);
    const status = reader.interface.takeDelimiterExclusive('\n') catch return false;
    return std.mem.startsWith(u8, status, "HTTP/1.1 204 ") or std.mem.startsWith(u8, status, "HTTP/1.0 204 ");
}

const Frontend = struct {
    directory: Io.Dir,
    config: []const u8,
    done: Io.Event = .unset,

    fn serve(self: *Frontend, io: Io, allocator: std.mem.Allocator, listener: *Io.net.Server) !void {
        defer self.done.set(io);
        // Los navegadores abren conexiones anticipadas: ninguna debe bloquear
        // la descarga de los demás archivos. El grupo cancela todas al cerrar.
        var requests: Io.Group = .init;
        defer requests.cancel(io);
        while (true) {
            const stream = try listener.accept(io);
            requests.concurrent(io, serveConnection, .{ self, io, allocator, stream }) catch |err| {
                stream.close(io);
                return err;
            };
        }
    }

    fn serveConnection(self: *Frontend, io: Io, allocator: std.mem.Allocator, stream: Io.net.Stream) Io.Cancelable!void {
        defer stream.close(io);
        var input: [8192]u8 = undefined;
        var output: [8192]u8 = undefined;
        var reader = stream.reader(io, &input);
        var writer = stream.writer(io, &output);
        var server = std.http.Server.init(&reader.interface, &writer.interface);
        self.respond(io, allocator, &server) catch |err| {
            // Reader/Writer envuelven Canceled; recuperarlo permite cerrar incluso
            // si un navegador dejó una conexión abierta sin enviar la cabecera.
            if (err == error.Canceled) return error.Canceled;
            if (reader.err) |read_error| {
                if (read_error == error.Canceled) return error.Canceled;
            }
            if (writer.err) |write_error| {
                if (write_error == error.Canceled) return error.Canceled;
            }
        };
    }

    fn respond(self: *Frontend, io: Io, allocator: std.mem.Allocator, server: *std.http.Server) !void {
        var request = try server.receiveHead();
        if (request.head.method != .GET and request.head.method != .HEAD)
            return request.respond("Método no permitido", .{ .status = .method_not_allowed, .keep_alive = false });
        const target = request.head.target;
        const path = target[0 .. std.mem.indexOfScalar(u8, target, '?') orelse target.len];
        if (std.mem.eql(u8, path, "/api-config.js")) {
            return request.respond(self.config, .{ .keep_alive = false, .extra_headers = &.{
                .{ .name = "Content-Type", .value = "application/javascript; charset=utf-8" },
                .{ .name = "Cache-Control", .value = "no-store" },
            } });
        }
        if (path.len == 0 or path[0] != '/')
            return request.respond("Ruta inválida", .{ .status = .bad_request, .keep_alive = false });
        const decoded = try allocator.dupe(u8, path[1..]);
        defer allocator.free(decoded);
        const relative = std.Uri.percentDecodeInPlace(decoded);
        var parts = std.mem.splitScalar(u8, relative, '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, "..") or std.mem.indexOfAny(u8, part, "\\\x00") != null)
                return request.respond("Ruta inválida", .{ .status = .bad_request, .keep_alive = false });
        }
        if (std.fs.path.isAbsolute(relative))
            return request.respond("Ruta inválida", .{ .status = .bad_request, .keep_alive = false });
        const file = if (relative.len == 0) "index.html" else relative;
        const contents = self.directory.readFileAlloc(io, file, allocator, .unlimited) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => return request.respond("Archivo no encontrado", .{ .status = .not_found, .keep_alive = false }),
        };
        defer allocator.free(contents);
        try request.respond(contents, .{ .keep_alive = false, .extra_headers = &.{
            .{ .name = "Content-Type", .value = mimeType(file) },
        } });
    }
};

fn mimeType(path: []const u8) []const u8 {
    const extension = std.fs.path.extension(path);
    const types = .{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".js", "application/javascript; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".wasm", "application/wasm" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".ico", "image/x-icon" },
    };
    inline for (types) |entry| {
        if (std.ascii.eqlIgnoreCase(extension, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}
