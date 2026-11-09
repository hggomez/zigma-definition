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
};

pub fn filesHere(b: *std.Build) PackageFiles {
    return .{
        .zigma = b.path("src/core/zigma.zig"),
        .json = b.path("src/json.zig"),
        .frontend_main = b.path("src/frontend/main.zig"),
        .frontend_js = b.path("src/frontend/main.js"),
        .frontend_html = b.path("src/frontend/index.html"),
        .frontend_api_config = b.path("src/frontend/api_config.js"),
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
    };
}

pub const AppOptions = struct {
    files: PackageFiles,
    system_root: std.Build.LazyPath,
    /// Contrato expuesto como `@import("contract")` a system_root.
    /// Si se omite, usa system_root como raíz del contrato.
    contract_root: ?std.Build.LazyPath = null,
    /// Mapa opcional del consumidor `dominio → widget`, instalado como `widgets.js`.
    widgets_js: ?std.Build.LazyPath = null,
    /// Título opcional de la pestaña, instalado como `title.js` generado.
    title: ?[]const u8 = null,
};

pub const App = struct {
    frontend: *std.Build.Step.Compile,
    /// Directorio instalado y paso que lo prepara, para conectarlos a addRuntime.
    frontend_directory: std.Build.LazyPath,
    frontend_step: *std.Build.Step,
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

/// Compila e instala el frontend WASM desde `system` (`type_defs` + `entity_defs`).
/// Su target es wasm32-freestanding y su optimización .small, independientes del backend.
pub fn addApp(b: *std.Build, opts: AppOptions) App {
    const files = opts.files;
    const contract_root = opts.contract_root orelse opts.system_root;

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_optimize: std.builtin.OptimizeMode = .small;

    const zigma_wasm = zigmaModule(b, files, wasm_target, wasm_optimize);
    const json_wasm = jsonModule(b, files, zigma_wasm, wasm_target, wasm_optimize);
    const contract_wasm = b.createModule(.{
        .root_source_file = contract_root,
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
            .{ .name = "contract", .module = contract_wasm },
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

    return .{
        .frontend = frontend,
        .frontend_directory = .{ .relative = .{ .base = .install_prefix, .sub_path = "frontend" } },
        .frontend_step = frontend_step,
    };
}

/// Igual que `addApp`, usando las rutas de una dependencia `zigma_definition`.
pub fn addAppFromDep(
    b: *std.Build,
    dep: *std.Build.Dependency,
    opts: struct {
        system_root: std.Build.LazyPath,
        contract_root: ?std.Build.LazyPath = null,
        widgets_js: ?std.Build.LazyPath = null,
        title: ?[]const u8 = null,
    },
) App {
    return addApp(b, .{
        .files = filesFromDependency(dep),
        .system_root = opts.system_root,
        .contract_root = opts.contract_root,
        .widgets_js = opts.widgets_js,
        .title = opts.title,
    });
}
