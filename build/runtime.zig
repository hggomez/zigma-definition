//! Compone un backend PostgreSQL y un lanzador sin conocer el dominio del consumidor.
const std = @import("std");

pub const RuntimeOptions = struct {
    name: []const u8 = "app",
    /// Publica Model; debe compartirse con el adaptador REST y la proyección PostgreSQL.
    contract: *std.Build.Module,
    /// Publica Api y, si Api.ValidationContext != void, ContextProvider.
    application_rest: *std.Build.Module,
    schema_guard: *std.Build.Module,
    frontend_directory: std.Build.LazyPath,
    /// Paso que instala/genera el frontend, si su directorio no es un LazyPath generado.
    frontend_step: ?*std.Build.Step = null,
    /// Directorio de ejecución que contiene db/. Por defecto, la raíz del consumidor.
    project_root: ?std.Build.LazyPath = null,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

pub const RuntimeModules = struct {
    crud: *std.Build.Module,
    libpq: *std.Build.Module,
    runner: *std.Build.Module,
    std_http: *std.Build.Module,
};

pub const Runtime = struct {
    backend: *std.Build.Step.Compile,
    launcher: *std.Build.Step.Compile,
    run_backend: *std.Build.Step.Run,
    run: *std.Build.Step.Run,
};

/// Declara artefactos y ejecuciones; el consumidor elige nombres de comandos e instalación.
/// Compilar el lanzador no requiere libpq ni un snapshot aceptado. Ejecutar solo el
/// backend no genera ni sirve el frontend. Ambos modos conservan el guard del backend.
pub fn addRuntime(
    b: *std.Build,
    framework_root: std.Build.LazyPath,
    modules: RuntimeModules,
    opts: RuntimeOptions,
) Runtime {
    const project_root = opts.project_root orelse b.path(".");
    const backend = b.addExecutable(.{
        .name = b.fmt("{s}-backend", .{opts.name}),
        .root_module = b.createModule(.{
            .root_source_file = framework_root.path(b, "src/server.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
            .imports = &.{
                .{ .name = "contract", .module = opts.contract },
                .{ .name = "application_rest", .module = opts.application_rest },
                .{ .name = "schema_guard", .module = opts.schema_guard },
                .{ .name = "zigma_postgres_crud", .module = modules.crud },
                .{ .name = "zigma_postgres_libpq", .module = modules.libpq },
                .{ .name = "zigma_liquibase_runner", .module = modules.runner },
                .{ .name = "zigma_std_http", .module = modules.std_http },
            },
        }),
    });
    const launcher = b.addExecutable(.{
        .name = b.fmt("{s}-launcher", .{opts.name}),
        .root_module = b.createModule(.{
            .root_source_file = framework_root.path(b, "src/runtime/launcher.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
        }),
    });
    const run_backend = b.addRunArtifact(backend);
    run_backend.setCwd(project_root);
    run_backend.has_side_effects = true;

    const run = b.addRunArtifact(launcher);
    run.addArtifactArg(backend);
    run.addDirectoryArg(opts.frontend_directory);
    if (opts.frontend_step) |step| run.step.dependOn(step);
    run.setCwd(project_root);
    run.has_side_effects = true;

    return .{ .backend = backend, .launcher = launcher, .run_backend = run_backend, .run = run };
}

pub fn addRuntimeFromDep(b: *std.Build, dep: *std.Build.Dependency, opts: RuntimeOptions) Runtime {
    return addRuntime(b, dep.path("."), .{
        .crud = dep.module("zigma_postgres_crud"),
        .libpq = dep.module("zigma_postgres_libpq"),
        .runner = dep.module("zigma_liquibase_runner"),
        .std_http = dep.module("zigma_std_http"),
    }, opts);
}
