//! Las pruebas pertenecen al consumidor; no agrega módulos al framework ni importa AIDA.
const std = @import("std");

const application = @import("application.zig");

pub fn addSteps(b: *std.Build, framework: *std.Build.Dependency, artifacts: application.Artifacts, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const contract = artifacts.modules.contract;
    const system = artifacts.modules.system;
    const pricing = artifacts.modules.pricing;
    const postgres = artifacts.modules.postgres;
    const imports: []const std.Build.Module.Import = &.{
        .{ .name = "zigma", .module = framework.module("zigma") },
        .{ .name = "supermercado", .module = contract },
        .{ .name = "system", .module = system },
        .{ .name = "pricing", .module = pricing },
        .{ .name = "postgres", .module = postgres },
        .{ .name = "zigma_postgres_migrations", .module = framework.module("zigma_postgres_migrations") },
    };
    const all = b.step("test", "Probar entidades, reglas comerciales y proyección PostgreSQL del supermercado (sin servicios)");
    inline for (.{
        .{ "test-model", "test/model_test.zig", "Probar las ocho entidades, sus claves y nulabilidad" },
        .{ "test-pricing", "test/pricing_test.zig", "Probar condiciones al abrir el carrito y descuentos por grupos completos" },
        .{ "test-schema", "test/postgres_test.zig", "Probar claves, tipos y referencias opcionales PostgreSQL sin conectar a una base" },
    }) |suite| {
        const binary = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(suite[1]),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }) });
        const run = b.addRunArtifact(binary);
        const step = b.step(suite[0], suite[2]);
        step.dependOn(&run.step);
        all.dependOn(step);
    }
    const rejections = b.step("test-compile-errors", "Rechazar campos obligatorios nulos, importes fraccionarios y referencias incompletas de precio");
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

    const application_rest = artifacts.modules.rest;
    const rest_binary = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/rest_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "supermercado", .module = contract },
            .{ .name = "zigma_rest", .module = framework.module("zigma_rest") },
            .{ .name = "application_rest", .module = application_rest },
        },
    }) });
    const rest_run = b.addRunArtifact(rest_binary);
    const rest_step = b.step("test-rest", "Probar codecs, validaciones y las ocho rutas CRUD del supermercado");
    rest_step.dependOn(&rest_run.step);
    all.dependOn(rest_step);
    all.dependOn(&artifacts.migrations.schema_guard.step);
    all.dependOn(&artifacts.migrations.schema_check.step);

    const frontend = b.addSystemCommand(&.{ "node", "--experimental-vm-modules" });
    frontend.addFileArg(b.path("test/integration/frontend_test.mjs"));
    frontend.addArtifactArg(artifacts.frontend.frontend);
    frontend.addFileArg(framework.path("src/frontend/main.js"));
    const frontend_step = b.step("test-frontend", "Probar catálogo y CRUD del frontend WASM (Node)");
    frontend_step.dependOn(&frontend.step);

    const application_tests = b.addSystemCommand(&.{"python3"});
    application_tests.addFileArg(b.path("test/integration/application_test.py"));
    application_tests.addArg(b.graph.zig_exe);
    application_tests.addArg("--framework-root");
    application_tests.addDirectoryArg(framework.path("."));
    application_tests.addPassthruArgs();
    application_tests.has_side_effects = true;
    const application_step = b.step("test-application", "Probar composición y paquete del supermercado (Python y Node)");
    application_step.dependOn(&application_tests.step);
    const local = b.step("test-local", "Probar modelo, REST y composición local del supermercado (sin servicios)");
    local.dependOn(all);
    local.dependOn(frontend_step);
    local.dependOn(application_step);
}

fn at(comptime file: []const u8) []const u8 {
    const sep = std.fs.path.sep_str;
    return std.fmt.comptimePrint("test{s}compile_errors{s}{s}:/?/", .{ sep, sep, file });
}

const compile_error_cases = [_]struct { file: []const u8, expected: []const u8 }{
    .{ .file = "required_price_null.zig", .expected = at("required_price_null.zig") },
    .{ .file = "required_quantity_null.zig", .expected = at("required_quantity_null.zig") },
    .{ .file = "floating_price.zig", .expected = at("floating_price.zig") },
    .{
        .file = "incomplete_price_fk.zig",
        .expected = "entity 'productos_carritos', fk 'precio': target fields do not match the complete pk nor any uk of entity 'productos_precios'",
    },
};
