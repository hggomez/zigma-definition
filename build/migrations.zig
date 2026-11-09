//! Composición del workflow de migraciones para cualquier aplicación consumidora.
//! Las rutas de fuentes pertenecen al framework; el historial pertenece al consumidor.
const std = @import("std");

pub const MigrationOptions = struct {
    /// Módulo con `pub const schema_snapshot` y `pub const baseline_ddl`, ambos strings.
    application_postgres: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Directorio que contiene db/. Por defecto es la raíz del build consumidor.
    project_root: ?std.Build.LazyPath = null,
    liquibase_bin: []const u8 = "liquibase",
};

pub const MigrationModules = struct {
    schema: *std.Build.Module,
    runner: *std.Build.Module,
    libpq: *std.Build.Module,
};

pub const Migrations = struct {
    migration_tool: *std.Build.Step.Compile,
    schema_guard: *std.Build.Step.Compile,
    schema_check: *std.Build.Step.Run,
    schema_validator: *std.Build.Step.Compile,
    migration_applier: *std.Build.Step.Compile,
};

/// Registra init-migrations, check-schema, migration, accept-migration y apply-migrations.
/// No conecta el guard al step por defecto: el consumidor decide qué artefactos protege.
/// init/migration/accept pueden compilarse antes de que el snapshot exista o coincida.
pub fn addMigrations(
    b: *std.Build,
    framework_root: std.Build.LazyPath,
    modules: MigrationModules,
    opts: MigrationOptions,
) Migrations {
    const project_root = opts.project_root orelse b.path(".");
    const tool = b.addExecutable(.{
        .name = "postgres-migration-tool",
        .root_module = b.createModule(.{
            .root_source_file = framework_root.path(b, "migration_tools/postgres_migration_tool.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
            .imports = &.{
                .{ .name = "application_postgres", .module = opts.application_postgres },
                .{ .name = "zigma_postgres_migrations", .module = modules.schema },
            },
        }),
    });

    const init = b.addRunArtifact(tool);
    init.addArg("init");
    init.setCwd(project_root);
    init.has_side_effects = true;
    b.step("init-migrations", "Create the initial Liquibase baseline and accepted snapshot").dependOn(&init.step);

    const check = b.addRunArtifact(tool);
    check.addArg("check");
    check.setCwd(project_root);
    // Lee el historial del filesystem, que puede cambiar sin recompilar la herramienta.
    check.has_side_effects = true;
    b.step("check-schema", "Compare the application with its accepted PostgreSQL snapshot").dependOn(&check.step);

    const draft = b.addRunArtifact(tool);
    draft.addArg("draft");
    if (b.option([]const u8, "name", "Optional migration name using letters, digits, and underscores")) |name|
        draft.addArg(name);
    draft.setCwd(project_root);
    draft.has_side_effects = true;
    b.step("migration", "Create a Liquibase SQL draft for the current entity changes").dependOn(&draft.step);

    const guard_module = b.createModule(.{
        .root_source_file = framework_root.path(b, "migration_tools/schema_guard.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{.{ .name = "application_postgres", .module = opts.application_postgres }},
    });
    guard_module.addAnonymousImport("accepted_snapshot", .{
        .root_source_file = project_root.path(b, "db/schema.snapshot.json"),
    });
    const guard = b.addObject(.{ .name = "postgres-schema-guard", .root_module = guard_module });

    const validator = b.addExecutable(.{
        .name = "postgres-schema-validator",
        .root_module = b.createModule(.{
            .root_source_file = framework_root.path(b, "migration_tools/postgres_schema_validator.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
            .imports = &.{
                .{ .name = "application_postgres", .module = opts.application_postgres },
                .{ .name = "zigma_postgres_libpq", .module = modules.libpq },
            },
        }),
    });
    const applier = b.addExecutable(.{
        .name = "apply-migrations",
        .root_module = b.createModule(.{
            .root_source_file = framework_root.path(b, "migration_tools/apply_migrations.zig"),
            .target = opts.target,
            .optimize = opts.optimize,
            .imports = &.{
                .{ .name = "zigma_liquibase_runner", .module = modules.runner },
                .{ .name = "schema_guard", .module = guard_module },
            },
        }),
    });
    const apply = b.addRunArtifact(applier);
    apply.setCwd(project_root);
    apply.has_side_effects = true;
    b.step("apply-migrations", "Apply the accepted Liquibase history without starting HTTP").dependOn(&apply.step);

    const accept = b.addSystemCommand(&.{"sh"});
    accept.addFileArg(framework_root.path(b, "migration_tools/accept_migration.sh"));
    accept.addArtifactArg(tool);
    accept.addArtifactArg(validator);
    accept.addArg(opts.liquibase_bin);
    accept.addDirectoryArg(project_root);
    accept.setCwd(project_root);
    accept.has_side_effects = true;
    b.step("accept-migration", "Verify the draft in disposable PostgreSQL, then accept it").dependOn(&accept.step);

    return .{
        .migration_tool = tool,
        .schema_guard = guard,
        .schema_check = check,
        .schema_validator = validator,
        .migration_applier = applier,
    };
}

/// Usa las fuentes y módulos publicados por una dependencia zigma_definition.
pub fn addMigrationsFromDep(b: *std.Build, dep: *std.Build.Dependency, opts: MigrationOptions) Migrations {
    return addMigrations(b, dep.path("."), .{
        .schema = dep.module("zigma_postgres_migrations"),
        .runner = dep.module("zigma_liquibase_runner"),
        .libpq = dep.module("zigma_postgres_libpq"),
    }, opts);
}
