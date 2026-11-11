//! Fixtures privados de las suites: no publica módulos ni comandos de aplicación.
//! Sus fuentes se leen únicamente al compilar los tests que las necesitan.
const std = @import("std");
const FrameworkModules = @import("modules.zig").Modules;
const migrations = @import("migrations.zig");

pub const Aida = struct {
    modules: struct {
        contract: *std.Build.Module,
        rest: *std.Build.Module,
        postgres: *std.Build.Module,
    },
    schema_guard: *std.Build.Step.Compile,
    schema_check: *std.Build.Step.Run,
    schema_validator: *std.Build.Step.Compile,
    migration_applier: *std.Build.Step.Compile,
    launcher: *std.Build.Step.Compile,
};

pub fn createAida(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, framework: FrameworkModules) Aida {
    const contract = b.createModule(.{
        .root_source_file = b.path("examples/aida/src/aida.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigma", .module = framework.zigma }},
    });
    const rest = b.createModule(.{
        .root_source_file = b.path("examples/aida/src/rest.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = framework.zigma },
            .{ .name = "zigma_rest", .module = framework.rest },
            .{ .name = "contract", .module = contract },
        },
    });
    const postgres = b.createModule(.{
        .root_source_file = b.path("examples/aida/src/postgres.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = framework.zigma },
            .{ .name = "aida", .module = contract },
            .{ .name = "zigma_postgres_ddl", .module = framework.postgres_ddl },
            .{ .name = "zigma_postgres_migrations", .module = framework.postgres_migrations },
        },
    });
    const history = migrations.createArtifacts(b, b.path("."), .{
        .schema = framework.postgres_migrations,
        .runner = framework.liquibase_runner,
        .libpq = framework.postgres_libpq,
    }, .{
        .application_postgres = postgres,
        .target = target,
        .optimize = optimize,
        .project_root = b.path("examples/aida"),
    });
    const launcher = b.addExecutable(.{
        .name = "test-launcher",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/runtime/launcher.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    return .{
        .modules = .{ .contract = contract, .rest = rest, .postgres = postgres },
        .schema_guard = history.schema_guard,
        .schema_check = history.schema_check,
        .schema_validator = history.schema_validator,
        .migration_applier = history.migration_applier,
        .launcher = launcher,
    };
}
