//! Entrada del build: configuración general y conexiones entre sus partes.
//! build() declara un grafo de tareas. Zig ejecuta después solo los nodos necesarios
//! para el comando elegido; dependOn significa «esta tarea necesita aquella».
//! Guía y ejemplos del grafo: docs/build.md.

const std = @import("std");
const app = @import("build/app.zig");
const project_modules = @import("build/modules.zig");
const aida_build = @import("build/aida.zig");
const tests = @import("build/tests.zig");

// API de build del paquete: los consumidores conservan sus imports y llamadas.
pub const PackageFiles = app.PackageFiles;
pub const AppOptions = app.AppOptions;
pub const App = app.App;
pub const filesHere = app.filesHere;
pub const filesFromDependency = app.filesFromDependency;
pub const addApp = app.addApp;
pub const addAppFromDep = app.addAppFromDep;

pub fn build(b: *std.Build) void {
    // Opciones compartidas por los artefactos nativos de este build.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const liquibase_bin = b.option([]const u8, "liquibase-bin", "Path to the pinned Liquibase 5.0.4 CLI") orelse "liquibase";

    // Publicar módulos y declarar ejecutables todavía no los compila ni ejecuta.
    const modules = project_modules.create(b, target, optimize);
    const aida = aida_build.addSteps(b, target, optimize, modules, liquibase_bin);

    // Sin comando explícito, zig build comprueba el schema aceptado de AIDA.
    // El arranque del servidor pertenece únicamente a run-aida/run-aida-rest.
    b.default_step.dependOn(&aida.schema_guard.step);
    b.default_step.dependOn(&aida.schema_check.step);

    // Las suites reutilizan los mismos módulos y artefactos, sin duplicarlos.
    tests.addSteps(b, target, optimize, modules, aida, liquibase_bin);
}
