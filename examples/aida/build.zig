const std = @import("std");
const application = @import("build/application.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zigma_dep = b.dependency("zigma_definition", .{
        .target = target,
        .optimize = optimize,
        .@"libpq-prefix" = b.option([]const u8, "libpq-prefix", "Prefix containing libpq include/ and lib/"),
        .@"libpq-include" = b.option([]const u8, "libpq-include", "Directory containing libpq-fe.h"),
        .@"libpq-lib" = b.option([]const u8, "libpq-lib", "Directory containing the libpq library"),
    });
    const liquibase_bin = b.option([]const u8, "liquibase-bin", "Path to the Liquibase CLI") orelse
        b.graph.environ_map.get("LIQUIBASE_BIN") orelse "liquibase";
    const app = application.addSteps(b, zigma_dep, .{
        .target = target,
        .optimize = optimize,
        .liquibase_bin = liquibase_bin,
    });

    // Variante de prueba del frontend real: fuerza el límite del buffer del catálogo.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const test_zigma = b.createModule(.{
        .root_source_file = zigma_dep.path("src/core/zigma.zig"),
        .target = wasm_target,
        .optimize = .small,
    });
    const test_json = b.createModule(.{
        .root_source_file = zigma_dep.path("src/json.zig"),
        .target = wasm_target,
        .optimize = .small,
        .imports = &.{.{ .name = "zigma", .module = test_zigma }},
    });
    const oversized_system = b.createModule(.{
        .root_source_file = zigma_dep.path("test/integration/frontend_oversized_system.zig"),
        .target = wasm_target,
        .optimize = .small,
        .imports = &.{.{ .name = "zigma", .module = test_zigma }},
    });
    const oversized_frontend = b.addExecutable(.{
        .name = "frontend-oversized-test",
        .root_module = b.createModule(.{
            .root_source_file = zigma_dep.path("src/frontend/main.zig"),
            .target = wasm_target,
            .optimize = .small,
            .imports = &.{
                .{ .name = "zigma", .module = test_zigma },
                .{ .name = "zigma_json", .module = test_json },
                .{ .name = "system", .module = oversized_system },
            },
        }),
    });
    oversized_frontend.entry = .disabled;
    oversized_frontend.rdynamic = true;
    oversized_frontend.export_memory = true;

    const run_frontend_test = b.addSystemCommand(&.{ "node", "--experimental-vm-modules" });
    run_frontend_test.addFileArg(zigma_dep.path("test/integration/run_frontend_test.mjs"));
    run_frontend_test.addArtifactArg(app.frontend);
    run_frontend_test.addArtifactArg(oversized_frontend);
    run_frontend_test.addFileArg(zigma_dep.path("src/frontend/main.js"));
    run_frontend_test.addFileArg(b.path("src/widgets.js"));
    const test_frontend_step = b.step("test-frontend", "Probar catálogo, controles y protocolo WASM del frontend (requiere Node)");
    test_frontend_step.dependOn(&run_frontend_test.step);
}
