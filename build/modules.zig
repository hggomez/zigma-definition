//! Módulos publicados e imports compartidos por los ejecutables y tests de la raíz.
//! addModule publica un nombre para consumidores; createModule crea un módulo interno.
//! Declararlos no los compila: eso ocurre cuando un artefacto los necesita.

const std = @import("std");

pub const Modules = struct {
    zigma: *std.Build.Module,
    aida: *std.Build.Module,
    json: *std.Build.Module,
    rest: *std.Build.Module,
    postgres_crud: *std.Build.Module,
    std_http: *std.Build.Module,
    aida_rest: *std.Build.Module,
    postgres_ddl: *std.Build.Module,
    postgres_executor_ddl: *std.Build.Module,
    postgres_migrations: *std.Build.Module,
    liquibase_runner: *std.Build.Module,
    aida_postgres: *std.Build.Module,
    postgres_libpq: *std.Build.Module,
};

/// Crea una sola instancia de cada módulo para el target y la optimización elegidos.
/// libpq queda en su rama del grafo; los tests locales no ejecutan su compilación.
pub fn create(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Modules {
    const zigma_mod = b.addModule("zigma", .{
        .root_source_file = b.path("src/core/zigma.zig"),
        .target = target,
        .optimize = optimize,
    });
    const aida_mod = b.addModule("aida", .{
        .root_source_file = b.path("examples/aida/src/aida.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
        },
    });
    const zigma_json_mod = b.addModule("zigma_json", .{
        .root_source_file = b.path("src/json.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
        },
    });

    const rest_mod = b.addModule("zigma_rest", .{
        .root_source_file = b.path("src/rest/api.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
        },
    });

    const postgres_crud_mod = b.addModule("zigma_postgres_crud", .{
        .root_source_file = b.path("src/postgres/crud.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
            .{ .name = "zigma_rest", .module = rest_mod },
        },
    });

    const std_http_mod = b.addModule("zigma_std_http", .{
        .root_source_file = b.path("src/rest/std_http.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma_rest", .module = rest_mod },
        },
    });

    const aida_rest_mod = b.addModule("aida_rest", .{
        .root_source_file = b.path("examples/aida/src/rest.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
            .{ .name = "zigma_rest", .module = rest_mod },
            .{ .name = "aida", .module = aida_mod },
        },
    });

    const postgres_ddl_mod = b.addModule("zigma_postgres_ddl", .{
        .root_source_file = b.path("src/postgres/ddl.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
        },
    });

    const postgres_executor_ddl_mod = b.addModule("zigma_postgres_executor_ddl", .{
        .root_source_file = b.path("src/postgres/executor_ddl.zig"),
        .target = target,
        .optimize = optimize,
    });

    const postgres_migrations_mod = b.addModule("zigma_postgres_migrations", .{
        .root_source_file = b.path("src/postgres/migrations/schema.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
            .{ .name = "zigma_postgres_ddl", .module = postgres_ddl_mod },
        },
    });

    const liquibase_runner_mod = b.addModule("zigma_liquibase_runner", .{
        .root_source_file = b.path("src/postgres/migrations/liquibase_runner.zig"),
        .target = target,
        .optimize = optimize,
    });

    const aida_postgres_mod = b.addModule("aida_postgres", .{
        .root_source_file = b.path("examples/aida/src/postgres.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
            .{ .name = "aida", .module = aida_mod },
            .{ .name = "zigma_postgres_ddl", .module = postgres_ddl_mod },
            .{ .name = "zigma_postgres_migrations", .module = postgres_migrations_mod },
        },
    });

    const libpq_prefix = b.option(
        []const u8,
        "libpq-prefix",
        "Prefijo que contiene los directorios include/ y lib/ de libpq",
    );
    const libpq_include = b.option(
        []const u8,
        "libpq-include",
        "Directorio de libpq-fe.h; tiene prioridad sobre libpq-prefix/include",
    );
    const libpq_lib = b.option(
        []const u8,
        "libpq-lib",
        "Directorio de la biblioteca libpq; tiene prioridad sobre libpq-prefix/lib",
    );
    const postgres_libpq_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/postgres/libpq.h"),
        .target = target,
        .optimize = optimize,
    });
    if (libpq_include) |include_dir| {
        postgres_libpq_translate.addSystemIncludePath(.{ .cwd_relative = include_dir });
    } else if (libpq_prefix) |prefix| {
        postgres_libpq_translate.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
    }
    const postgres_libpq_bindings_mod = postgres_libpq_translate.createModule();
    postgres_libpq_bindings_mod.linkSystemLibrary("pq", .{});
    if (libpq_lib) |lib_dir| {
        postgres_libpq_bindings_mod.addLibraryPath(.{ .cwd_relative = lib_dir });
    } else if (libpq_prefix) |prefix| {
        postgres_libpq_bindings_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    }

    const postgres_libpq_mod = b.addModule("zigma_postgres_libpq", .{
        .root_source_file = b.path("src/postgres/libpq.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma_postgres_executor_ddl", .module = postgres_executor_ddl_mod },
            .{ .name = "libpq", .module = postgres_libpq_bindings_mod },
        },
    });

    return .{
        .zigma = zigma_mod,
        .aida = aida_mod,
        .json = zigma_json_mod,
        .rest = rest_mod,
        .postgres_crud = postgres_crud_mod,
        .std_http = std_http_mod,
        .aida_rest = aida_rest_mod,
        .postgres_ddl = postgres_ddl_mod,
        .postgres_executor_ddl = postgres_executor_ddl_mod,
        .postgres_migrations = postgres_migrations_mod,
        .liquibase_runner = liquibase_runner_mod,
        .aida_postgres = aida_postgres_mod,
        .postgres_libpq = postgres_libpq_mod,
    };
}
