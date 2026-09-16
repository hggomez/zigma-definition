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
}
