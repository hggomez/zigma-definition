//! Adaptador bloqueante de runtime para el CLI externo de Liquibase.
//!
//! La generación de migraciones sigue siendo pura. Las aplicaciones llaman a
//! `update` antes de recibir tráfico; Liquibase gestiona los checksums del changelog,
//! los bloqueos y la aplicación de changesets pendientes.

const std = @import("std");
const builtin = @import("builtin");

pub const Config = struct {
    // Nombre que se resuelve mediante PATH o ruta absoluta explícita al ejecutable.
    executable: []const u8 = "liquibase",
    // Se mantiene como opción de argv porque es configuración del proceso sin secretos.
    changelog_file: []const u8,
    // La información de conexión JDBC puede ser sensible y se pasa por el ambiente
    // del proceso hijo, en lugar de la línea de comandos visible.
    jdbc_url: []const u8,
    username: ?[]const u8 = null,
    password: ?[]const u8 = null,
    schema_name: []const u8 = "public",
};

pub const Error = error{
    OutOfMemory,
    InvalidConfiguration,
    LiquibaseNotFound,
    LiquibaseSpawnFailed,
    LiquibaseFailed,
};

const ProcessLauncher = struct {
    // Zig 0.17 canaliza las operaciones de procesos mediante una implementación explícita de
    // Io.
    io: std.Io,

    fn run(
        self: ProcessLauncher,
        argv: []const []const u8,
        environment: *const std.process.Environ.Map,
    ) Error!std.process.Child.Term {
        // Una ruta absoluta se puede comprobar directamente para informar con claridad
        // si falta el ejecutable antes de spawn. La búsqueda por PATH queda a cargo de spawn.
        if (std.fs.path.isAbsolute(argv[0])) {
            std.Io.Dir.accessAbsolute(self.io, argv[0], .{}) catch |err| switch (err) {
                error.FileNotFound => return error.LiquibaseNotFound,
                else => return error.LiquibaseSpawnFailed,
            };
        }
        // No interviene un shell: cada elemento de argv se pasa como un único argumento,
        // evitando diferencias de comillas o inyección entre plataformas.
        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .environ_map = environment,
            // Los diagnósticos de Liquibase quedan visibles para el operador de la aplicación.
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.LiquibaseNotFound,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.LiquibaseSpawnFailed,
        };
        // Si ocurre un error después de spawn y antes de completar wait, se intenta
        // evitar que quede un proceso hijo huérfano.
        errdefer child.kill(self.io);
        return child.wait(self.io) catch return error.LiquibaseSpawnFailed;
    }
};

fn systemEnvironment() std.process.Environ {
    // Construye la vista prestada específica de la plataforma que espera la API de
    // procesos de Zig. Los destinos POSIX nativos exponen el vector C `environ`, terminado en null.
    return switch (builtin.os.tag) {
        .windows, .wasi, .emscripten => .{ .block = .global },
        .freestanding, .other => .empty,
        else => blk: {
            const length = std.mem.len(std.c.environ);
            break :blk .{ .block = .{ .slice = std.c.environ[0..length :null] } };
        },
    };
}

fn currentEnvironment(allocator: std.mem.Allocator) Error!std.process.Environ.Map {
    // Clona el ambiente antes de editarlo para que las credenciales y la configuración
    // del proceso hijo de Liquibase no modifiquen el ambiente de la aplicación padre.
    return systemEnvironment().createMap(allocator) catch return error.OutOfMemory;
}

// Estos nombres pertenecen al contrato de configuración de la aplicación de
// ejemplo, no al CLI de Liquibase. Liquibase 5 valida todas las variables heredadas
// LIQUIBASE_* y rechaza nombres desconocidos. El hijo no debe heredarlas después
// de que sus valores se hayan copiado a Config.
const application_environment_variables = [_][]const u8{
    "LIQUIBASE_BIN",
    "LIQUIBASE_CHANGELOG",
    "LIQUIBASE_PASSWORD",
    "LIQUIBASE_SCHEMA",
    "LIQUIBASE_URL",
    "LIQUIBASE_USERNAME",
};

fn validConfig(config: Config) bool {
    // Un ejecutable, changelog, URL o schema vacío no permite una invocación válida
    // y se rechaza antes de reservar memoria o iniciar el proceso.
    if (config.executable.len == 0 or config.changelog_file.len == 0 or
        config.jdbc_url.len == 0 or config.schema_name.len == 0)
        return false;
    inline for (.{ config.executable, config.changelog_file, config.jdbc_url, config.schema_name }) |value| {
        if (std.mem.indexOfScalar(u8, value, 0) != null) return false;
    }
    if (config.username) |value| if (std.mem.indexOfScalar(u8, value, 0) != null) return false;
    if (config.password) |value| if (std.mem.indexOfScalar(u8, value, 0) != null) return false;
    return true;
}

/// Ejecuta `liquibase update` con un lanzador estructural inyectado. Es público
/// para probar la política de arranque sin instalar Java ni Liquibase;
/// las aplicaciones normales llaman a `update`.
pub fn updateWith(
    allocator: std.mem.Allocator,
    config: Config,
    launcher: anytype,
) Error!void {
    // Separar esta función de `update` permite inyectar un lanzador falso en los tests
    // y examinar argv y el ambiente sin tener Java ni Liquibase instalados.
    if (!validConfig(config)) return error.InvalidConfiguration;

    // Las opciones sin secretos se reservan como elementos completos de argv.
    // Nunca se concatenan para formar un comando de shell.
    const changelog_arg = std.fmt.allocPrint(allocator, "--changelog-file={s}", .{config.changelog_file}) catch
        return error.OutOfMemory;
    defer allocator.free(changelog_arg);
    const schema_arg = std.fmt.allocPrint(allocator, "--default-schema-name={s}", .{config.schema_name}) catch
        return error.OutOfMemory;
    defer allocator.free(schema_arg);

    // Parte del ambiente normal para conservar PATH, JAVA_HOME y la configuración
    // de Liquibase. Elimina los aliases de la aplicación antes de agregar las variables
    // oficiales de comandos de Liquibase que consume el proceso hijo.
    var environment = try currentEnvironment(allocator);
    defer environment.deinit();
    for (application_environment_variables) |name|
        _ = environment.swapRemove(name);
    // Las credenciales se excluyen de argv y de los listados de procesos.
    environment.put("LIQUIBASE_COMMAND_URL", config.jdbc_url) catch return error.OutOfMemory;
    if (config.username) |username| {
        environment.put("LIQUIBASE_COMMAND_USERNAME", username) catch return error.OutOfMemory;
    } else {
        // Elimina los valores heredados cuando quien llama indica explícitamente que no
        // hay usuario; de otro modo, el shell padre podría afectar esta invocación.
        _ = environment.swapRemove("LIQUIBASE_COMMAND_USERNAME");
    }
    if (config.password) |password| {
        environment.put("LIQUIBASE_COMMAND_PASSWORD", password) catch return error.OutOfMemory;
    } else {
        _ = environment.swapRemove("LIQUIBASE_COMMAND_PASSWORD");
    }

    // El orden estable facilita las aserciones del lanzador falso y los diagnósticos del
    // operador.
    const argv = [_][]const u8{
        config.executable,
        changelog_arg,
        schema_arg,
        "update",
    };
    // Liquibase indica el éxito de la migración mediante el estado de salida del proceso.
    const term = try launcher.run(&argv, &environment);
    if (!term.success()) return error.LiquibaseFailed;
}

/// Ejecuta el CLI externo de Liquibase en forma síncrona. Las credenciales se
/// pasan por el ambiente del hijo y nunca aparecen en su vector de argumentos.
pub fn update(allocator: std.mem.Allocator, config: Config) Error!void {
    // El adaptador es síncrono: se deshabilitan las operaciones en segundo plano
    // y concurrentes del motor Io temporal. El arranque espera a que termine Liquibase.
    var threaded_io = std.Io.Threaded.init(allocator, .{
        .environ = systemEnvironment(),
        .async_limit = .nothing,
        .concurrent_limit = .nothing,
    });
    defer threaded_io.deinit();
    // Delega toda la política a la función comprobable; este wrapper solo aporta
    // el lanzador real de procesos del sistema operativo.
    return updateWith(allocator, config, ProcessLauncher{ .io = threaded_io.io() });
}
// Los strings del ambiente y argv se representan abajo como strings C. Un NUL
// interno haría que el hijo observe bytes distintos de los que se validaron.
