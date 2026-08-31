//! Blocking runtime adapter for the external Liquibase CLI.
//!
//! Migration generation remains pure. Applications call `update` before
//! serving traffic; Liquibase owns changelog checksums, locking, and applying
//! pending changesets.

const std = @import("std");
const builtin = @import("builtin");

pub const Config = struct {
    executable: []const u8 = "liquibase",
    changelog_file: []const u8,
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
    io: std.Io,

    fn run(
        self: ProcessLauncher,
        argv: []const []const u8,
        environment: *const std.process.Environ.Map,
    ) Error!std.process.Child.Term {
        if (std.fs.path.isAbsolute(argv[0])) {
            std.Io.Dir.accessAbsolute(self.io, argv[0], .{}) catch |err| switch (err) {
                error.FileNotFound => return error.LiquibaseNotFound,
                else => return error.LiquibaseSpawnFailed,
            };
        }
        var child = std.process.spawn(self.io, .{
            .argv = argv,
            .environ_map = environment,
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |err| switch (err) {
            error.FileNotFound => return error.LiquibaseNotFound,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.LiquibaseSpawnFailed,
        };
        errdefer child.kill(self.io);
        return child.wait(self.io) catch return error.LiquibaseSpawnFailed;
    }
};

fn systemEnvironment() std.process.Environ {
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
    return systemEnvironment().createMap(allocator) catch return error.OutOfMemory;
}

fn validConfig(config: Config) bool {
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

/// Executes `liquibase update` using an injected structural launcher. This is
/// public so consumers can test startup policy without installing Java or
/// Liquibase; normal applications call `update`.
pub fn updateWith(
    allocator: std.mem.Allocator,
    config: Config,
    launcher: anytype,
) Error!void {
    if (!validConfig(config)) return error.InvalidConfiguration;

    const changelog_arg = std.fmt.allocPrint(allocator, "--changelog-file={s}", .{config.changelog_file}) catch
        return error.OutOfMemory;
    defer allocator.free(changelog_arg);
    const schema_arg = std.fmt.allocPrint(allocator, "--default-schema-name={s}", .{config.schema_name}) catch
        return error.OutOfMemory;
    defer allocator.free(schema_arg);

    var environment = try currentEnvironment(allocator);
    defer environment.deinit();
    environment.put("LIQUIBASE_COMMAND_URL", config.jdbc_url) catch return error.OutOfMemory;
    if (config.username) |username| {
        environment.put("LIQUIBASE_COMMAND_USERNAME", username) catch return error.OutOfMemory;
    } else {
        _ = environment.swapRemove("LIQUIBASE_COMMAND_USERNAME");
    }
    if (config.password) |password| {
        environment.put("LIQUIBASE_COMMAND_PASSWORD", password) catch return error.OutOfMemory;
    } else {
        _ = environment.swapRemove("LIQUIBASE_COMMAND_PASSWORD");
    }

    const argv = [_][]const u8{
        config.executable,
        changelog_arg,
        schema_arg,
        "update",
    };
    const term = try launcher.run(&argv, &environment);
    if (!term.success()) return error.LiquibaseFailed;
}

/// Runs the external Liquibase CLI synchronously. Credentials are supplied to
/// the child environment and never appear in its argument vector.
pub fn update(allocator: std.mem.Allocator, config: Config) Error!void {
    var threaded_io = std.Io.Threaded.init(allocator, .{
        .environ = systemEnvironment(),
        .async_limit = .nothing,
        .concurrent_limit = .nothing,
    });
    defer threaded_io.deinit();
    return updateWith(allocator, config, ProcessLauncher{ .io = threaded_io.io() });
}
