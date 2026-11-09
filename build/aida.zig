//! Aplicación PostgreSQL de AIDA y herramientas de su ciclo de migraciones.
//! addExecutable declara qué compilar; addRunArtifact declara cómo ejecutarlo.
//! Cada comando público se conecta a esas tareas mediante step.dependOn.

const std = @import("std");
const Modules = @import("modules.zig").Modules;
const migration_build = @import("migrations.zig");
const runtime_build = @import("runtime.zig");

/// Nodos compartidos con las comprobaciones de la raíz y las integraciones.
/// Reutilizarlos evita crear ejecutables o módulos duplicados.
pub const Artifacts = struct {
    schema_guard: *std.Build.Step.Compile,
    schema_check: *std.Build.Step.Run,
    launcher: *std.Build.Step.Compile,
    schema_validator: *std.Build.Step.Compile,
    migration_applier: *std.Build.Step.Compile,
};

pub fn addSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: Modules,
    liquibase_bin: []const u8,
) Artifacts {
    const application_root = b.path("examples/aida");
    const migrations = migration_build.addMigrations(b, b.path("."), .{
        .schema = modules.postgres_migrations,
        .runner = modules.liquibase_runner,
        .libpq = modules.postgres_libpq,
    }, .{
        .application_postgres = modules.aida_postgres,
        .target = target,
        .optimize = optimize,
        .project_root = application_root,
        .liquibase_bin = liquibase_bin,
    });

    // El frontend conserva el build consumidor; las entradas nativas son compartidas.
    const build_aida_frontend = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "frontend" });
    build_aida_frontend.setCwd(application_root);
    const runtime = runtime_build.addRuntime(b, b.path("."), .{
        .crud = modules.postgres_crud,
        .libpq = modules.postgres_libpq,
        .runner = modules.liquibase_runner,
        .std_http = modules.std_http,
    }, .{
        .name = "aida",
        .contract = modules.aida,
        .application_rest = modules.aida_rest,
        .schema_guard = migrations.schema_guard.root_module,
        .frontend_directory = b.path("examples/aida/zig-out/frontend"),
        .frontend_step = &build_aida_frontend.step,
        .project_root = application_root,
        .target = target,
        .optimize = optimize,
    });
    b.step("run-aida-rest", "Apply migrations and serve the generated AIDA REST API")
        .dependOn(&runtime.run_backend.step);
    b.step("check-aida-rest", "Compile the generated AIDA REST server without running it")
        .dependOn(&runtime.backend.step);
    b.step("run-aida", "Iniciar AIDA con PostgreSQL y frontend").dependOn(&runtime.run.step);

    const check_aida = b.step("check-aida", "Compilar el backend PostgreSQL y el frontend de AIDA sin ejecutarlos");
    check_aida.dependOn(&runtime.backend.step);
    check_aida.dependOn(&runtime.launcher.step);
    check_aida.dependOn(&build_aida_frontend.step);

    return .{
        .schema_guard = migrations.schema_guard,
        .schema_check = migrations.schema_check,
        .launcher = runtime.launcher,
        .schema_validator = migrations.schema_validator,
        .migration_applier = migrations.migration_applier,
    };
}
