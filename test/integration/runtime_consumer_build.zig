//! Consumidor sin main.zig ni server.zig propios.
const std = @import("std");
const zigma = @import("zigma_definition");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("zigma_definition", .{
        .target = target,
        .optimize = optimize,
        .@"libpq-prefix" = b.option([]const u8, "libpq-prefix", "Prefix containing libpq"),
        .@"libpq-include" = b.option([]const u8, "libpq-include", "Directory containing libpq-fe.h"),
        .@"libpq-lib" = b.option([]const u8, "libpq-lib", "Directory containing libpq library"),
    });
    const options = b.addOptions();
    options.addOption(bool, "extended", b.option(bool, "extended", "Add a nullable column") orelse false);
    const contract = b.createModule(.{
        .root_source_file = b.path("contract.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = dep.module("zigma") },
            .{ .name = "fixture_options", .module = options.createModule() },
        },
    });
    const application_rest = b.createModule(.{
        .root_source_file = b.path("rest.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "contract", .module = contract },
            .{ .name = "zigma_rest", .module = dep.module("zigma_rest") },
        },
    });
    const postgres = b.createModule(.{
        .root_source_file = b.path("postgres.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "contract", .module = contract },
            .{ .name = "zigma_postgres_ddl", .module = dep.module("zigma_postgres_ddl") },
            .{ .name = "zigma_postgres_migrations", .module = dep.module("zigma_postgres_migrations") },
        },
    });
    const project_root = b.path("application workspace");
    const migrations = zigma.addMigrationsFromDep(b, dep, .{
        .application_postgres = postgres,
        .project_root = project_root,
        .target = target,
        .optimize = optimize,
    });
    const frontend = b.addWriteFiles();
    _ = frontend.add("index.html", "<h1>Inventory</h1>");
    const runtime = zigma.addRuntimeFromDep(b, dep, .{
        .name = "inventory",
        .contract = contract,
        .application_rest = application_rest,
        .schema_guard = migrations.schema_guard.root_module,
        .frontend_directory = frontend.getDirectory(),
        .project_root = project_root,
        .target = target,
        .optimize = optimize,
    });
    b.step("run", "Run backend and frontend").dependOn(&runtime.run.step);
    b.step("run-backend", "Run only the PostgreSQL backend").dependOn(&runtime.run_backend.step);
    b.step("check-backend", "Compile the backend and schema guard").dependOn(&runtime.backend.step);
    const install_launcher = b.addInstallArtifact(runtime.launcher, .{});
    b.step("install-launcher", "Install the independent launcher").dependOn(&install_launcher.step);
    const install_backend = b.addInstallArtifact(runtime.backend, .{});
    const install_frontend = b.addInstallDirectory(.{
        .source_dir = frontend.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "frontend",
    });
    const install_runtime = b.step("install-runtime", "Install the complete runtime for integration tests");
    install_runtime.dependOn(&install_launcher.step);
    install_runtime.dependOn(&install_backend.step);
    install_runtime.dependOn(&install_frontend.step);
}
