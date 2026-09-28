//! API de build que usan los paquetes consumidores para generar su aplicación.
//! b.path se resuelve respecto del paquete que posee b, no de este archivo;
//! dep.path localiza las fuentes de Zigma desde el build de otro paquete.

const std = @import("std");

/// Fuentes del paquete necesarias para que un consumidor compile los generadores.
pub const PackageFiles = struct {
    zigma: std.Build.LazyPath,
    json: std.Build.LazyPath,
    frontend_main: std.Build.LazyPath,
    frontend_js: std.Build.LazyPath,
    frontend_html: std.Build.LazyPath,
    frontend_api_config: std.Build.LazyPath,
    testing_backend: std.Build.LazyPath,
    std_http: std.Build.LazyPath,
    rest: std.Build.LazyPath,
    memory_repository: std.Build.LazyPath,
};

pub fn filesHere(b: *std.Build) PackageFiles {
    return .{
        .zigma = b.path("src/core/zigma.zig"),
        .json = b.path("src/json.zig"),
        .frontend_main = b.path("src/frontend/main.zig"),
        .frontend_js = b.path("src/frontend/main.js"),
        .frontend_html = b.path("src/frontend/index.html"),
        .frontend_api_config = b.path("src/frontend/api_config.js"),
        .testing_backend = b.path("src/testing_backend/main.zig"),
        .std_http = b.path("src/rest/std_http.zig"),
        .rest = b.path("src/rest/api.zig"),
        .memory_repository = b.path("src/testing_backend/memory_repository.zig"),
    };
}

pub fn filesFromDependency(dep: *std.Build.Dependency) PackageFiles {
    return .{
        .zigma = dep.path("src/core/zigma.zig"),
        .json = dep.path("src/json.zig"),
        .frontend_main = dep.path("src/frontend/main.zig"),
        .frontend_js = dep.path("src/frontend/main.js"),
        .frontend_html = dep.path("src/frontend/index.html"),
        .frontend_api_config = dep.path("src/frontend/api_config.js"),
        .testing_backend = dep.path("src/testing_backend/main.zig"),
        .std_http = dep.path("src/rest/std_http.zig"),
        .rest = dep.path("src/rest/api.zig"),
        .memory_repository = dep.path("src/testing_backend/memory_repository.zig"),
    };
}

pub const AppOptions = struct {
    files: PackageFiles,
    system_root: std.Build.LazyPath,
    /// Controlador REST del consumidor (`Api`, codecs), requerido por el backend en memoria.
    rest_root: std.Build.LazyPath,
    /// Módulo opcional que provee `@import("aida")` a `rest_root`, compartido con el sistema.
    aida_root: ?std.Build.LazyPath = null,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Mapa opcional del consumidor `dominio → widget`, instalado como `widgets.js`.
    widgets_js: ?std.Build.LazyPath = null,
    /// Título opcional de la pestaña, instalado como `title.js` generado.
    title: ?[]const u8 = null,
};

pub const App = struct {
    testing_backend: *std.Build.Step.Compile,
    frontend: *std.Build.Step.Compile,
    run_testing_backend: *std.Build.Step.Run,
};

fn zigmaModule(
    b: *std.Build,
    files: PackageFiles,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = files.zigma,
        .target = target,
        .optimize = optimize,
    });
}

fn jsonModule(
    b: *std.Build,
    files: PackageFiles,
    zigma: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = files.json,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma },
        },
    });
}

/// Compila un backend de pruebas en memoria y un frontend WASM desde el mismo `system`.
/// (`type_defs` + `entity_defs`; `seeds` opcional). Cada target tiene sus propias
/// instancias de `zigma` / `zigma_json` / `system`: nativo y WASM no comparten módulos.
pub fn addApp(b: *std.Build, opts: AppOptions) App {
    const files = opts.files;

    const zigma_native = zigmaModule(b, files, opts.target, opts.optimize);
    const aida_root = opts.aida_root orelse opts.system_root;
    const aida_native = b.createModule(.{
        .root_source_file = aida_root,
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_native },
        },
    });
    const system_native = b.createModule(.{
        .root_source_file = opts.system_root,
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_native },
            .{ .name = "aida", .module = aida_native },
        },
    });
    const rest_native = b.createModule(.{
        .root_source_file = files.rest,
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_native },
        },
    });
    const app_rest_native = b.createModule(.{
        .root_source_file = opts.rest_root,
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_native },
            .{ .name = "zigma_rest", .module = rest_native },
            .{ .name = "aida", .module = aida_native },
        },
    });
    const memory_repo_native = b.createModule(.{
        .root_source_file = files.memory_repository,
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "zigma_rest", .module = rest_native },
        },
    });

    const std_http_native = b.createModule(.{
        .root_source_file = files.std_http,
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "zigma_rest", .module = rest_native },
        },
    });
    const testing_backend = b.addExecutable(.{
        .name = "testing-backend",
        .root_module = b.createModule(.{
            .root_source_file = files.testing_backend,
            .target = opts.target,
            .optimize = opts.optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_native },
                .{ .name = "zigma_rest", .module = rest_native },
                .{ .name = "system", .module = system_native },
                .{ .name = "app_rest", .module = app_rest_native },
                .{ .name = "memory_repository", .module = memory_repo_native },
                .{ .name = "zigma_std_http", .module = std_http_native },
            },
        }),
    });
    b.installArtifact(testing_backend);

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_optimize: std.builtin.OptimizeMode = .small;

    const zigma_wasm = zigmaModule(b, files, wasm_target, wasm_optimize);
    const json_wasm = jsonModule(b, files, zigma_wasm, wasm_target, wasm_optimize);
    const aida_wasm = b.createModule(.{
        .root_source_file = aida_root,
        .target = wasm_target,
        .optimize = wasm_optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_wasm },
        },
    });
    const system_wasm = b.createModule(.{
        .root_source_file = opts.system_root,
        .target = wasm_target,
        .optimize = wasm_optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_wasm },
            .{ .name = "aida", .module = aida_wasm },
        },
    });

    const frontend = b.addExecutable(.{
        .name = "frontend",
        .root_module = b.createModule(.{
            .root_source_file = files.frontend_main,
            .target = wasm_target,
            .optimize = wasm_optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_wasm },
                .{ .name = "zigma_json", .module = json_wasm },
                .{ .name = "system", .module = system_wasm },
            },
        }),
    });
    frontend.entry = .disabled;
    frontend.rdynamic = true;
    frontend.export_memory = true;

    const frontend_dir: std.Build.InstallDir = .{ .custom = "frontend" };
    const install_wasm = b.addInstallArtifact(frontend, .{
        .dest_dir = .{ .override = frontend_dir },
    });
    b.getInstallStep().dependOn(&install_wasm.step);

    const frontend_step = b.step("frontend", "Build and install the WASM frontend");
    frontend_step.dependOn(&install_wasm.step);

    const install_js = b.addInstallFileWithDir(files.frontend_js, frontend_dir, "main.js");
    const install_html = b.addInstallFileWithDir(files.frontend_html, frontend_dir, "index.html");
    b.getInstallStep().dependOn(&install_js.step);
    b.getInstallStep().dependOn(&install_html.step);
    frontend_step.dependOn(&install_js.step);
    frontend_step.dependOn(&install_html.step);

    const install_api_config = b.addInstallFileWithDir(files.frontend_api_config, frontend_dir, "api-config.js");
    b.getInstallStep().dependOn(&install_api_config.step);
    frontend_step.dependOn(&install_api_config.step);

    const title_js = b.addWriteFiles().add(
        "title.js",
        b.fmt("document.title = {f};\n", .{std.json.fmt(opts.title orelse "", .{})}),
    );
    const install_title = b.addInstallFileWithDir(title_js, frontend_dir, "title.js");
    b.getInstallStep().dependOn(&install_title.step);
    frontend_step.dependOn(&install_title.step);

    if (opts.widgets_js) |widgets_js| {
        const install_widgets = b.addInstallFileWithDir(widgets_js, frontend_dir, "widgets.js");
        b.getInstallStep().dependOn(&install_widgets.step);
        frontend_step.dependOn(&install_widgets.step);
    }

    const run_testing_backend = b.addRunArtifact(testing_backend);
    run_testing_backend.has_side_effects = true;
    const testing_backend_step = b.step("testing-backend", "Ejecutar el backend de pruebas en memoria (sin PostgreSQL)");
    testing_backend_step.dependOn(&run_testing_backend.step);

    return .{
        .testing_backend = testing_backend,
        .frontend = frontend,
        .run_testing_backend = run_testing_backend,
    };
}

/// Igual que `addApp`, usando las rutas de una dependencia `zigma_definition`.
pub fn addAppFromDep(
    b: *std.Build,
    dep: *std.Build.Dependency,
    opts: struct {
        system_root: std.Build.LazyPath,
        rest_root: std.Build.LazyPath,
        aida_root: ?std.Build.LazyPath = null,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        widgets_js: ?std.Build.LazyPath = null,
        title: ?[]const u8 = null,
    },
) App {
    return addApp(b, .{
        .files = filesFromDependency(dep),
        .system_root = opts.system_root,
        .rest_root = opts.rest_root,
        .aida_root = opts.aida_root,
        .target = opts.target,
        .optimize = opts.optimize,
        .widgets_js = opts.widgets_js,
        .title = opts.title,
    });
}
