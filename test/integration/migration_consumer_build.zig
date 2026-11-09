//! Build de un paquete consumidor creado en un directorio temporal por la prueba.
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
    const postgres = b.createModule(.{
        .root_source_file = b.path("postgres.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = dep.module("zigma") },
            .{ .name = "zigma_postgres_ddl", .module = dep.module("zigma_postgres_ddl") },
            .{ .name = "zigma_postgres_migrations", .module = dep.module("zigma_postgres_migrations") },
            .{ .name = "fixture_options", .module = options.createModule() },
        },
    });
    const migrations = zigma.addMigrationsFromDep(b, dep, .{
        .application_postgres = postgres,
        .target = target,
        .optimize = optimize,
        .project_root = b.path(b.option([]const u8, "history-root", "Directory containing db/") orelse "."),
        .liquibase_bin = b.option([]const u8, "liquibase-bin", "Liquibase executable") orelse "liquibase",
    });
    b.default_step.dependOn(&migrations.schema_guard.step);
}
