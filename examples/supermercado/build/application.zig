//! Build completo de Supermercado mediante la API pública de su dependencia Zigma.
const std = @import("std");
const zigma = @import("zigma_definition");
const application_modules = @import("modules.zig");

pub const Artifacts = struct {
    frontend: zigma.App,
    modules: application_modules.Modules,
    migrations: zigma.Migrations,
};

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    liquibase_bin: []const u8,
};

pub fn addSteps(b: *std.Build, dep: *std.Build.Dependency, opts: Options) Artifacts {
    const app = zigma.addAppFromDep(b, dep, .{
        .system_root = b.path("src/system.zig"),
        .contract_root = b.path("src/supermercado.zig"),
        .title = "Supermercado",
    });
    const modules = application_modules.create(b, dep, opts.target, opts.optimize);
    const migrations = zigma.addMigrationsFromDep(b, dep, .{
        .application_postgres = modules.postgres,
        .target = opts.target,
        .optimize = opts.optimize,
        .liquibase_bin = opts.liquibase_bin,
    });
    const runtime = zigma.addRuntimeFromDep(b, dep, .{
        .name = "supermercado",
        .contract = modules.contract,
        .application_rest = modules.rest,
        .schema_guard = migrations.schema_guard.root_module,
        .frontend_directory = app.frontend_directory,
        .frontend_step = app.frontend_step,
        .target = opts.target,
        .optimize = opts.optimize,
    });
    runtime.run.setEnvironmentVariable("LIQUIBASE_BIN", opts.liquibase_bin);
    runtime.run_backend.setEnvironmentVariable("LIQUIBASE_BIN", opts.liquibase_bin);
    if (localLiquibaseClasspath(b, dep)) |classpath| {
        runtime.run.setEnvironmentVariable("LIQUIBASE_CLASSPATH", classpath);
        runtime.run_backend.setEnvironmentVariable("LIQUIBASE_CLASSPATH", classpath);
    }
    b.installArtifact(runtime.backend);
    b.installArtifact(runtime.launcher);
    b.getInstallStep().dependOn(&migrations.schema_check.step);
    b.step("run", "Apply migrations and start Supermercado with its frontend").dependOn(&runtime.run.step);
    b.step("run-backend", "Apply migrations and start the Supermercado REST API").dependOn(&runtime.run_backend.step);
    b.step("check-backend", "Compile the Supermercado REST server without running it").dependOn(&runtime.backend.step);
    const check = b.step("check", "Compile Supermercado and check its accepted schema without running it");
    check.dependOn(&runtime.backend.step);
    check.dependOn(&runtime.launcher.step);
    check.dependOn(app.frontend_step);
    check.dependOn(&migrations.schema_check.step);
    return .{ .frontend = app, .modules = modules, .migrations = migrations };
}

fn localLiquibaseClasspath(b: *std.Build, dep: *std.Build.Dependency) ?[]const u8 {
    // El ambiente y los drivers locales se observan en cada invocación.
    b.graph.poisonCache();
    if (b.graph.environ_map.get("LIQUIBASE_CLASSPATH") != null) return null;
    // Primero los drivers propios; después la ubicación histórica del repositorio.
    return directoryClasspath(b, b.root) orelse directoryClasspath(b, dep.builder.root);
}

fn directoryClasspath(b: *std.Build, root: std.Build.Cache.Path) ?[]const u8 {
    const io = b.graph.io;
    const allocator = b.allocator;
    var directory = root.openDir(io, "liquibase_libs", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => std.debug.panic("cannot open liquibase_libs: {t}", .{err}),
    };
    defer directory.close(io);

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_length = directory.realPath(io, &path_buffer) catch |err|
        std.debug.panic("cannot resolve liquibase_libs: {t}", .{err});
    var jars: std.ArrayList([]const u8) = .empty;
    var entries = directory.iterate();
    while (entries.next(io) catch |err| std.debug.panic("cannot read liquibase_libs: {t}", .{err})) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jar")) continue;
        jars.append(allocator, b.pathJoin(&.{ path_buffer[0..path_length], entry.name })) catch @panic("OOM");
    }
    if (jars.items.len == 0) return null;

    // Orden estable; el classpath usa el separador del host que ejecuta Liquibase.
    std.mem.sort([]const u8, jars.items, {}, struct {
        fn lessThan(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    const separator = if (@import("builtin").os.tag == .windows) ";" else ":";
    return std.mem.join(allocator, separator, jars.items) catch @panic("OOM");
}
