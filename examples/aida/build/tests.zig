//! Pruebas del consumidor: dominio, adaptación REST, schema y frontend.
const std = @import("std");
const zigma = @import("zigma_definition");
const application = @import("application.zig");

pub const LibpqOptions = struct {
    prefix: ?[]const u8,
    include: ?[]const u8,
    lib: ?[]const u8,
};

pub fn addSteps(b: *std.Build, dep: *std.Build.Dependency, artifacts: application.Artifacts, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, libpq: LibpqOptions) void {
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "zigma", .module = dep.module("zigma") },
        .{ .name = "zigma_rest", .module = dep.module("zigma_rest") },
        .{ .name = "aida", .module = artifacts.modules.contract },
        .{ .name = "aida_rest", .module = artifacts.modules.rest },
        .{ .name = "aida_postgres", .module = artifacts.modules.postgres },
    };
    const all = b.step("test", "Probar dominio, REST, schema y rechazos de AIDA (sin servicios)");
    for ([_][]const u8{
        "fecha_test.zig",
        "fecha_codec_test.zig",
        "fecha_rest_test.zig",
        "docente_age_test.zig",
        "docente_age_rest_test.zig",
        "aida_rest_test.zig",
        "aida_nullable_test.zig",
        "aida_schema_reference_test.zig",
        "business_rules_test.zig",
        "validation_context_test.zig",
    }) |file| {
        const binary = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("test/{s}", .{file})),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }) });
        const run = b.addRunArtifact(binary);
        all.dependOn(&run.step);
    }
    const rejections = b.step("test-compile-errors", "Probar los rechazos de tipos y campos de Cargo");
    for (compile_error_cases) |case| {
        const object = b.addObject(.{
            .name = case.file[0 .. case.file.len - 4],
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("test/compile_errors/{s}", .{case.file})),
                .target = target,
                .optimize = optimize,
                .imports = imports,
            }),
        });
        object.expect_errors = .{ .contains = case.expected };
        rejections.dependOn(&object.step);
    }
    all.dependOn(rejections);
    all.dependOn(&artifacts.migrations.schema_guard.step);
    all.dependOn(&artifacts.migrations.schema_check.step);

    const frontend = addFrontendTests(b, dep, artifacts.frontend);
    const local = b.step("test-local", "Probar dominio y frontend de AIDA (Node; sin servicios)");
    local.dependOn(all);
    local.dependOn(frontend);

    // Esta integración necesita libpq; queda fuera de las suites sin servicios.
    const classpath = b.addSystemCommand(&.{"python3"});
    classpath.addFileArg(b.path("test/integration/run_classpath_test.py"));
    classpath.addArg(b.graph.zig_exe);
    classpath.addArg("--framework-root");
    classpath.addDirectoryArg(dep.path("."));
    inline for (.{
        .{ "libpq-prefix", libpq.prefix },
        .{ "libpq-include", libpq.include },
        .{ "libpq-lib", libpq.lib },
    }) |option| {
        if (option[1]) |value|
            classpath.addArg(b.fmt("--{s}={s}", .{ option[0], value }));
    }
    classpath.has_side_effects = true;
    b.step("test-classpath", "Probar detección de drivers JDBC de AIDA (Python y libpq)").dependOn(&classpath.step);
}

fn at(comptime file: []const u8) []const u8 {
    const sep = std.fs.path.sep_str;
    return std.fmt.comptimePrint("test{s}compile_errors{s}{s}:/?/", .{ sep, sep, file });
}

const compile_error_cases = [_]struct { file: []const u8, expected: []const u8 }{
    .{ .file = "cargo_wrong_field_type.zig", .expected = "expected type '?i64', found '*const [1:0]u8'" },
    .{ .file = "validar_cargo_missing_field.zig", .expected = at("validar_cargo_missing_field.zig") },
    .{ .file = "cargo_unknown_field.zig", .expected = at("cargo_unknown_field.zig") },
};

fn addFrontendTests(b: *std.Build, dep: *std.Build.Dependency, app: zigma.App) *std.Build.Step {
    // Variante de prueba del frontend real: fuerza el límite del buffer del catálogo.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const test_zigma = b.createModule(.{
        .root_source_file = dep.path("src/core/zigma.zig"),
        .target = wasm_target,
        .optimize = .small,
    });
    const test_json = b.createModule(.{
        .root_source_file = dep.path("src/json.zig"),
        .target = wasm_target,
        .optimize = .small,
        .imports = &.{.{ .name = "zigma", .module = test_zigma }},
    });
    const oversized_system = b.createModule(.{
        .root_source_file = dep.path("test/integration/frontend_oversized_system.zig"),
        .target = wasm_target,
        .optimize = .small,
        .imports = &.{.{ .name = "zigma", .module = test_zigma }},
    });
    const oversized_frontend = b.addExecutable(.{
        .name = "frontend-oversized-test",
        .root_module = b.createModule(.{
            .root_source_file = dep.path("src/frontend/main.zig"),
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
    run_frontend_test.addFileArg(dep.path("test/integration/run_frontend_test.mjs"));
    run_frontend_test.addArtifactArg(app.frontend);
    run_frontend_test.addArtifactArg(oversized_frontend);
    run_frontend_test.addFileArg(dep.path("src/frontend/main.js"));
    run_frontend_test.addFileArg(b.path("src/widgets.js"));
    const test_frontend_step = b.step("test-frontend", "Probar catálogo, controles y protocolo WASM del frontend (requiere Node)");
    test_frontend_step.dependOn(&run_frontend_test.step);
    return test_frontend_step;
}
