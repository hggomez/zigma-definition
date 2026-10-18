const std = @import("std");
const zigma_build = @import("zigma_definition");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigma_dep = b.dependency("zigma_definition", .{});
    const app = zigma_build.addAppFromDep(b, zigma_dep, .{
        .system_root = b.path("src/system.zig"),
        .rest_root = b.path("src/rest.zig"),
        .aida_root = b.path("src/aida.zig"),
        .widgets_js = b.path("src/widgets.js"),
        .title = "aida",
        .target = target,
        .optimize = optimize,
    });

    // La prueba levanta un proceso propio en un puerto libre y no requiere PostgreSQL.
    const run_backend_test = b.addSystemCommand(&.{"python3"});
    run_backend_test.addFileArg(zigma_dep.path("test/integration/run_testing_backend.py"));
    run_backend_test.addArtifactArg(app.testing_backend);
    const test_backend_step = b.step("test-backend", "Probar por HTTP el backend de pruebas en memoria (requiere Python 3)");
    test_backend_step.dependOn(&run_backend_test.step);

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
