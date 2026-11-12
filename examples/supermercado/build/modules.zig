//! Módulos nativos privados, compartidos por la aplicación y sus pruebas.
const std = @import("std");

pub const Modules = struct {
    contract: *std.Build.Module,
    rest: *std.Build.Module,
    postgres: *std.Build.Module,
    pricing: *std.Build.Module,
    system: *std.Build.Module,
};

pub fn create(b: *std.Build, dep: *std.Build.Dependency, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Modules {
    const instant = b.createModule(.{
        .root_source_file = b.path("src/instant.zig"),
        .target = target,
        .optimize = optimize,
    });
    const contract = b.createModule(.{
        .root_source_file = b.path("src/supermercado.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "zigma", .module = dep.module("zigma") }},
    });
    const rest = b.createModule(.{
        .root_source_file = b.path("src/rest.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = dep.module("zigma") },
            .{ .name = "zigma_rest", .module = dep.module("zigma_rest") },
            .{ .name = "contract", .module = contract },
            .{ .name = "instant", .module = instant },
        },
    });
    const postgres = b.createModule(.{
        .root_source_file = b.path("src/postgres.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = dep.module("zigma") },
            .{ .name = "contract", .module = contract },
            .{ .name = "zigma_postgres_ddl", .module = dep.module("zigma_postgres_ddl") },
            .{ .name = "zigma_postgres_migrations", .module = dep.module("zigma_postgres_migrations") },
        },
    });
    const pricing = b.createModule(.{
        .root_source_file = b.path("src/pricing.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "contract", .module = contract },
            .{ .name = "instant", .module = instant },
        },
    });
    const system = b.createModule(.{
        .root_source_file = b.path("src/system.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "contract", .module = contract }},
    });
    return .{ .contract = contract, .rest = rest, .postgres = postgres, .pricing = pricing, .system = system };
}
