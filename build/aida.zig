//! Aplicación PostgreSQL de AIDA y herramientas de su ciclo de migraciones.
//! addExecutable declara qué compilar; addRunArtifact declara cómo ejecutarlo.
//! Cada comando público se conecta a esas tareas mediante step.dependOn.

const std = @import("std");
const Modules = @import("modules.zig").Modules;

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
    // Snapshot y generación de drafts: no necesitan conectarse a PostgreSQL.
    const migration_tool = b.addExecutable(.{
        .name = "postgres-migration-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/postgres_migration_tool.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida_postgres", .module = modules.aida_postgres },
                .{ .name = "zigma_postgres_migrations", .module = modules.postgres_migrations },
            },
        }),
    });

    const run_init_migrations = b.addRunArtifact(migration_tool);
    run_init_migrations.addArg("init");
    const init_migrations_step = b.step("init-migrations", "Create the initial Liquibase baseline and accepted snapshot");
    init_migrations_step.dependOn(&run_init_migrations.step);

    const run_schema_check = b.addRunArtifact(migration_tool);
    run_schema_check.addArg("check");
    const schema_check_step = b.step("check-schema", "Compare AIDA with the accepted PostgreSQL schema snapshot");
    schema_check_step.dependOn(&run_schema_check.step);

    const run_create_migration = b.addRunArtifact(migration_tool);
    run_create_migration.addArg("draft");
    if (b.option([]const u8, "name", "Optional migration name override using letters, digits, and underscores")) |name|
        run_create_migration.addArg(name);
    const migration_step = b.step("migration", "Create an automatically named Liquibase SQL draft for the current entity changes");
    migration_step.dependOn(&run_create_migration.step);

    const schema_guard_mod = b.createModule(.{
        .root_source_file = b.path("db/schema_guard.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma_postgres_migrations", .module = modules.postgres_migrations },
            .{ .name = "aida_postgres", .module = modules.aida_postgres },
            .{ .name = "aida", .module = modules.aida },
        },
    });
    const schema_guard = b.addObject(.{
        .name = "aida-postgres-schema-guard",
        .root_module = schema_guard_mod,
    });

    // Servidor y frontend: check compila; run agrega la ejecución.
    const aida_rest_server = b.addExecutable(.{
        .name = "aida-rest-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/aida/src/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida", .module = modules.aida },
                .{ .name = "aida_rest", .module = modules.aida_rest },
                .{ .name = "zigma_postgres_crud", .module = modules.postgres_crud },
                .{ .name = "zigma_postgres_libpq", .module = modules.postgres_libpq },
                .{ .name = "zigma_liquibase_runner", .module = modules.liquibase_runner },
                .{ .name = "zigma_std_http", .module = modules.std_http },
                .{ .name = "aida_schema_guard", .module = schema_guard_mod },
            },
        }),
    });
    const run_aida_rest_server = b.addRunArtifact(aida_rest_server);
    const aida_rest_server_step = b.step(
        "run-aida-rest",
        "Apply migrations and serve the generated AIDA REST API",
    );
    aida_rest_server_step.dependOn(&run_aida_rest_server.step);
    const check_aida_rest_server_step = b.step(
        "check-aida-rest",
        "Compile the generated AIDA REST server without running it",
    );
    check_aida_rest_server_step.dependOn(&aida_rest_server.step);

    // Reutiliza el build del consumidor con el mismo compilador y contrato de AIDA.
    const build_aida_frontend = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "frontend" });
    build_aida_frontend.setCwd(b.path("examples/aida"));
    const aida_launcher = b.addExecutable(.{
        .name = "aida-launcher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/aida/src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_aida = b.addRunArtifact(aida_launcher);
    run_aida.addArtifactArg(aida_rest_server);
    run_aida.addDirectoryArg(b.path("examples/aida/zig-out/frontend"));
    run_aida.setCwd(b.path("."));
    run_aida.has_side_effects = true;
    run_aida.step.dependOn(&build_aida_frontend.step);
    const run_aida_step = b.step("run-aida", "Iniciar AIDA con PostgreSQL y frontend");
    run_aida_step.dependOn(&run_aida.step);

    const check_aida_step = b.step("check-aida", "Compilar el backend PostgreSQL y el frontend de AIDA sin ejecutarlos");
    check_aida_step.dependOn(&aida_rest_server.step);
    check_aida_step.dependOn(&build_aida_frontend.step);
    check_aida_step.dependOn(&aida_launcher.step);

    // Herramientas de verificación y aplicación del historial aceptado.
    const schema_validator = b.addExecutable(.{
        .name = "postgres-schema-validator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/postgres_schema_validator.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida_postgres", .module = modules.aida_postgres },
                .{ .name = "zigma_postgres_libpq", .module = modules.postgres_libpq },
            },
        }),
    });

    const migration_applier = b.addExecutable(.{
        .name = "apply-migrations",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/apply_migrations.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma_liquibase_runner", .module = modules.liquibase_runner },
                .{ .name = "aida_schema_guard", .module = schema_guard_mod },
            },
        }),
    });
    const run_apply_migrations = b.addRunArtifact(migration_applier);
    run_apply_migrations.setCwd(b.path("."));
    run_apply_migrations.has_side_effects = true;
    const apply_migrations_step = b.step(
        "apply-migrations",
        "Aplicar las migraciones aceptadas de AIDA y terminar, sin iniciar HTTP",
    );
    apply_migrations_step.dependOn(&run_apply_migrations.step);

    // Verifica el borrador antes de incorporarlo al historial aceptado.
    const accept_migration = b.addSystemCommand(&.{"sh"});
    accept_migration.addFileArg(b.path("tools/accept_migration.sh"));
    accept_migration.addArtifactArg(migration_tool);
    accept_migration.addArtifactArg(schema_validator);
    accept_migration.addArg(liquibase_bin);
    accept_migration.addDirectoryArg(b.path("."));
    const accept_migration_step = b.step("accept-migration", "Verify the draft in disposable PostgreSQL, then accept it");
    accept_migration_step.dependOn(&accept_migration.step);

    return .{
        .schema_guard = schema_guard,
        .schema_check = run_schema_check,
        .launcher = aida_launcher,
        .schema_validator = schema_validator,
        .migration_applier = migration_applier,
    };
}
