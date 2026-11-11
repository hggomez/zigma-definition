//! Entrada del build: configuración general y conexiones entre sus partes.
//! build() declara un grafo de tareas. Zig ejecuta después solo los nodos necesarios
//! para el comando elegido; dependOn significa «esta tarea necesita aquella».
//! Guía y ejemplos del grafo: docs/build.md.

const std = @import("std");
const app = @import("build/app.zig");
const migrations = @import("build/migrations.zig");
const runtime = @import("build/runtime.zig");
const project_modules = @import("build/modules.zig");
const tests = @import("build/tests.zig");

// API de build del paquete: los consumidores conservan sus imports y llamadas.
pub const PackageFiles = app.PackageFiles;
pub const AppOptions = app.AppOptions;
pub const App = app.App;
pub const filesHere = app.filesHere;
pub const filesFromDependency = app.filesFromDependency;
pub const addApp = app.addApp;
pub const addAppFromDep = app.addAppFromDep;
pub const MigrationOptions = migrations.MigrationOptions;
pub const MigrationModules = migrations.MigrationModules;
pub const Migrations = migrations.Migrations;
pub const addMigrations = migrations.addMigrations;
pub const addMigrationsFromDep = migrations.addMigrationsFromDep;
pub const RuntimeOptions = runtime.RuntimeOptions;
pub const RuntimeModules = runtime.RuntimeModules;
pub const Runtime = runtime.Runtime;
pub const addRuntime = runtime.addRuntime;
pub const addRuntimeFromDep = runtime.addRuntimeFromDep;

pub fn build(b: *std.Build) void {
    // Opciones compartidas por los artefactos nativos de este build.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const liquibase_bin = b.option([]const u8, "liquibase-bin", "Path to the pinned Liquibase 5.0.4 CLI") orelse "liquibase";

    // Publicar módulos y declarar ejecutables todavía no los compila ni ejecuta.
    const modules = project_modules.create(b, target, optimize);
    // El build por defecto publica la biblioteca sin construir ninguna aplicación.
    // Los fixtures solo se compilan al seleccionar las suites correspondientes.
    tests.addSteps(b, target, optimize, modules, liquibase_bin);
}
