const std = @import("std");

/// El error debe estar EN la expresión marcada de este fragmento: su ruta,
/// tal como la imprime el compilador, debe iniciar la línea del error. Se usa
/// para mensajes nativos cuyo final no es estable (puede incluir el nombre
/// interno de un struct anónimo) y no admite una comparación literal. El
/// separador es el del sistema anfitrión (`/` en POSIX, `\` en Windows), como
/// lo imprime el compilador, para que los casos funcionen en ambos sistemas.
/// Es una constante comptime: toda la ruta se concatena en compilación.
fn at(comptime file: []const u8) []const u8 {
    const sep = std.fs.path.sep_str;
    return std.fmt.comptimePrint("test{s}compile_errors{s}{s}:/?/", .{ sep, sep, file });
}

/// Casos de error de compilación esperado: cada archivo de test/compile_errors
/// debe FALLAR al compilar con el error indicado (ver Step.Compile.expect_errors).
/// La comparación es por línea: un string sin comodín debe ser el FINAL de una
/// línea de error. Con /?/, el texto anterior debe iniciar la línea y el posterior
/// debe terminarla. Solo el primer /?/ es un comodín; no hay expresiones regulares:
/// esas dos formas son todo el vocabulario. Para los mensajes del framework,
/// que controlamos y por eso son estables, se usa el mensaje completo; para los
/// nativos se usa `at` (ver arriba).
const CompileErrorCase = struct { file: []const u8, expected: []const u8 };

const compile_error_cases = [_]struct { file: []const u8, expected: []const u8 }{
    .{ .file = "types_not_a_typedef.zig", .expected = "type 'text': must be a TypeDef (like zigma.TypeDef{ .Type = i64 })" },
    .{ .file = "types_extra_property.zig", .expected = "type 'fecha': must be a TypeDef (like zigma.TypeDef{ .Type = i64 })" },
    .{ .file = "record_unknown_type.zig", .expected = "unknown type 'inexistente'" },
    .{ .file = "record_unknown_property.zig", .expected = "unknown property 'colour'" },
    .{ .file = "record_is_name_false.zig", .expected = "is_name only admits true in a definition (false is the default)" },
    .{ .file = "instance_wrong_value_type.zig", .expected = "expected type '?i64', found '*const [6:0]u8'" },
    .{ .file = "instance_unknown_field.zig", .expected = at("instance_unknown_field.zig") },
    .{ .file = "entity_pk_not_in_fields.zig", .expected = "pk field 'inexistente' is not a field of the entity" },
    .{ .file = "entity_pk_partially_wrong.zig", .expected = "pk field 'inexistente' is not a field of the entity" },
    .{ .file = "entity_fk_source_not_in_fields_list.zig", .expected = "source field 'inexistente' is not a field of the entity" },
    .{ .file = "entity_fk_source_not_in_fields_map.zig", .expected = "source field 'inexistente' is not a field of the entity" },
    .{ .file = "entity_uk_not_in_fields.zig", .expected = "uk field 'inexistente' is not a field of the entity" },
    .{ .file = "extract_pk_no_field.zig", .expected = at("extract_pk_no_field.zig") },
    .{ .file = "system_fk_unknown_entity.zig", .expected = "unknown target entity 'inexistentes'" },
    .{ .file = "system_fk_partial_pk.zig", .expected = "target fields do not match the complete pk nor any uk of entity 'franjas'" },
    .{ .file = "info_fks_no_array_form.zig", .expected = at("info_fks_no_array_form.zig") },
    .{ .file = "defined_type_wrong_field_type.zig", .expected = "expected type '?i64', found '*const [1:0]u8'" },
    .{ .file = "validar_cargo_missing_field.zig", .expected = at("validar_cargo_missing_field.zig") },
    .{ .file = "defined_type_no_field.zig", .expected = at("defined_type_no_field.zig") },
    .{ .file = "postgres_ddl_mapping_missing.zig", .expected = "entity 'clases', field 'fecha': missing PostgreSQL type mapping for domain type 'fecha'" },
    .{ .file = "postgres_ddl_mapping_invalid.zig", .expected = "PostgreSQL type mapping 'text': 'sql_type' must be a non-empty string" },
    .{ .file = "postgres_ddl_unknown_table.zig", .expected = "PostgreSQL DDL: unknown entity 'inexistentes'" },
    .{ .file = "postgres_ddl_identifier_too_long.zig", .expected = "PostgreSQL identifier 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' exceeds 63 bytes" },
    .{ .file = "postgres_ddl_fk_cycle.zig", .expected = "PostgreSQL DDL: foreign key cycle involving entity 'lefts' cannot be generated with inline constraints" },
    .{ .file = "postgres_migrations_snapshot_stale.zig", .expected = "PostgreSQL schema differs from db/schema.snapshot.json; run 'zig build migration'" },
    .{ .file = "rest_codec_missing.zig", .expected = "entity 'events', field 'when': missing REST codec for domain type 'fecha'" },
    .{ .file = "rest_codec_invalid.zig", .expected = "REST codec 'text': must be a zigma_rest.Codec" },
    .{ .file = "rest_business_validator_unknown_entity.zig", .expected = "REST business validator 'missing': unknown entity" },
    .{ .file = "rest_business_validator_invalid.zig", .expected = "REST business validator 'things': must be a zigma_rest.BusinessValidator" },
};

// Los tests de contrato de la primera etapa también tienen el paso `test-model`.
// Se compara el diagnóstico esperado para que un fallo de compilación ajeno al
// caso no haga pasar un test de rechazo mientras falta implementar la nueva API.
const model_compile_error_cases = [_]CompileErrorCase{
    .{ .file = "types_optional_domain.zig", .expected = "type 'optional_integer': domain types must be non-optional; use field 'nullable'" },
    .{ .file = "record_optional_domain.zig", .expected = "type 'optional_integer': domain types must be non-optional; use field 'nullable'" },
    .{ .file = "system_optional_domain.zig", .expected = "type 'optional_integer': domain types must be non-optional; use field 'nullable'" },
    .{ .file = "system_row_unknown_entity.zig", .expected = "system: unknown entity 'missing'" },
    .{ .file = "system_projection_unknown_field.zig", .expected = "entity 'things': projection field 'missing' is not a field of the entity" },
    .{ .file = "system_projection_duplicate_field.zig", .expected = "entity 'things': duplicate projection field 'note'" },
    .{ .file = "system_rule_unknown_field.zig", .expected = "rule 'display': field 'missing' is not a field of the entity" },
    .{ .file = "system_rule_duplicate_field.zig", .expected = "rule 'display': duplicate field 'note'" },
    .{ .file = "system_rule_unknown_name.zig", .expected = "entity 'things': unknown rule 'missing'" },
    .{ .file = "entity_rules_invalid.zig", .expected = "entity definition: 'rules' must be a struct of rule definitions" },
    .{ .file = "entity_rule_invalid.zig", .expected = "rule 'display': must be a struct with a 'fields' list" },
    .{ .file = "entity_rule_missing_fields.zig", .expected = "rule 'display': missing 'fields'" },
    .{ .file = "entity_rule_invalid_fields.zig", .expected = "rule 'display': 'fields' must be a list of field names" },
    .{ .file = "entity_rule_unknown_property.zig", .expected = "rule 'display': unknown property 'field'" },
    .{ .file = "system_row_missing_nullable.zig", .expected = "missing struct field: note" },
    .{ .file = "system_patch_required_null.zig", .expected = "expected type 'bool', found '@TypeOf(null)'" },
};

/// Source files of this package, so a consumer can compile the generators.
pub const PackageFiles = struct {
    zigma: std.Build.LazyPath,
    json: std.Build.LazyPath,
    frontend_main: std.Build.LazyPath,
    frontend_js: std.Build.LazyPath,
    frontend_html: std.Build.LazyPath,
    http: std.Build.LazyPath,
};

pub fn filesHere(b: *std.Build) PackageFiles {
    return .{
        .zigma = b.path("src/zigma.zig"),
        .json = b.path("src/json.zig"),
        .frontend_main = b.path("src/frontend/main.zig"),
        .frontend_js = b.path("src/frontend/main.js"),
        .frontend_html = b.path("src/frontend/index.html"),
        .http = b.path("src/http/main.zig"),
    };
}

pub fn filesFromDependency(dep: *std.Build.Dependency) PackageFiles {
    return .{
        .zigma = dep.path("src/zigma.zig"),
        .json = dep.path("src/json.zig"),
        .frontend_main = dep.path("src/frontend/main.zig"),
        .frontend_js = dep.path("src/frontend/main.js"),
        .frontend_html = dep.path("src/frontend/index.html"),
        .http = dep.path("src/http/main.zig"),
    };
}

pub const AppOptions = struct {
    files: PackageFiles,
    system_root: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    /// Optional consumer map `domain type → widget`; installed as `widgets.js`.
    widgets_js: ?std.Build.LazyPath = null,
    /// Optional browser tab title; installed as generated `title.js`.
    title: ?[]const u8 = null,
};

pub const App = struct {
    backend: *std.Build.Step.Compile,
    frontend: *std.Build.Step.Compile,
    run_backend: *std.Build.Step.Run,
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

fn systemModule(
    b: *std.Build,
    system_root: std.Build.LazyPath,
    zigma: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = system_root,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma },
        },
    });
}

/// Compile a native HTTP backend and a WASM frontend from the same `system` file
/// (`type_defs` + `entity_defs`; optional `seeds`). Each artifact gets its own
/// `zigma` / `zigma_json` / `system` module instance so native and wasm32 do not share a target.
pub fn addApp(b: *std.Build, opts: AppOptions) App {
    const files = opts.files;

    const zigma_native = zigmaModule(b, files, opts.target, opts.optimize);
    const json_native = jsonModule(b, files, zigma_native, opts.target, opts.optimize);
    const system_native = systemModule(b, opts.system_root, zigma_native, opts.target, opts.optimize);

    const backend = b.addExecutable(.{
        .name = "backend",
        .root_module = b.createModule(.{
            .root_source_file = files.http,
            .target = opts.target,
            .optimize = opts.optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_native },
                .{ .name = "zigma_json", .module = json_native },
                .{ .name = "system", .module = system_native },
            },
        }),
    });
    b.installArtifact(backend);

    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
    });
    const wasm_optimize: std.builtin.OptimizeMode = .small;

    const zigma_wasm = zigmaModule(b, files, wasm_target, wasm_optimize);
    const json_wasm = jsonModule(b, files, zigma_wasm, wasm_target, wasm_optimize);
    const system_wasm = systemModule(b, opts.system_root, zigma_wasm, wasm_target, wasm_optimize);

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

    const run_backend = b.addRunArtifact(backend);
    run_backend.has_side_effects = true;
    const backend_step = b.step("backend", "Run the HTTP backend generated from the system module");
    backend_step.dependOn(&run_backend.step);
    const dummy_step = b.step("dummy", "Run the HTTP backend (alias of backend)");
    dummy_step.dependOn(&run_backend.step);

    return .{
        .backend = backend,
        .frontend = frontend,
        .run_backend = run_backend,
    };
}

/// Same as `addApp`, using paths from a `zigma_definition` dependency.
pub fn addAppFromDep(
    b: *std.Build,
    dep: *std.Build.Dependency,
    opts: struct {
        system_root: std.Build.LazyPath,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        widgets_js: ?std.Build.LazyPath = null,
        title: ?[]const u8 = null,
    },
) App {
    return addApp(b, .{
        .files = filesFromDependency(dep),
        .system_root = opts.system_root,
        .target = opts.target,
        .optimize = opts.optimize,
        .widgets_js = opts.widgets_js,
        .title = opts.title,
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigma_mod = b.addModule("zigma", .{
        .root_source_file = b.path("src/framework/zigma.zig"),
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
        .root_source_file = b.path("examples/aida_rest.zig"),
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
        .root_source_file = b.path("examples/aida_postgres.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
            .{ .name = "aida", .module = aida_mod },
            .{ .name = "zigma_postgres_ddl", .module = postgres_ddl_mod },
            .{ .name = "zigma_postgres_migrations", .module = postgres_migrations_mod },
        },
    });

    const migration_tool = b.addExecutable(.{
        .name = "postgres-migration-tool",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/postgres_migration_tool.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida_postgres", .module = aida_postgres_mod },
                .{ .name = "zigma_postgres_migrations", .module = postgres_migrations_mod },
            },
        }),
    });

    const run_init_migrations = b.addRunArtifact(migration_tool);
    run_init_migrations.addArg("init");
    const init_migrations_step = b.step("init-migrations", "Create the initial Liquibase baseline and accepted snapshot");
    init_migrations_step.dependOn(&run_init_migrations.step);

    const run_schema_check = b.addRunArtifact(migration_tool);
    run_schema_check.addArg("check");
    const schema_check_step = b.step("check-schema", "Compare AIDA with the accepted PostgreSQL schema snapshot");
    schema_check_step.dependOn(&run_schema_check.step);

    const run_create_migration = b.addRunArtifact(migration_tool);
    run_create_migration.addArg("draft");
    if (b.option([]const u8, "name", "Optional migration name override using letters, digits, and underscores")) |name|
        run_create_migration.addArg(name);
    const migration_step = b.step("migration", "Create an automatically named Liquibase SQL draft for the current entity changes");
    migration_step.dependOn(&run_create_migration.step);

    const schema_guard_mod = b.createModule(.{
        .root_source_file = b.path("db/schema_guard.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma_postgres_migrations", .module = postgres_migrations_mod },
            .{ .name = "aida_postgres", .module = aida_postgres_mod },
            .{ .name = "aida", .module = aida_mod },
        },
    });
    const schema_guard = b.addObject(.{
        .name = "aida-postgres-schema-guard",
        .root_module = schema_guard_mod,
    });
    b.default_step.dependOn(&schema_guard.step);
    b.default_step.dependOn(&run_schema_check.step);

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

    const aida_rest_server = b.addExecutable(.{
        .name = "aida-rest-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/aida_rest_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "aida_rest", .module = aida_rest_mod },
                .{ .name = "zigma_postgres_crud", .module = postgres_crud_mod },
                .{ .name = "zigma_postgres_libpq", .module = postgres_libpq_mod },
                .{ .name = "zigma_liquibase_runner", .module = liquibase_runner_mod },
                .{ .name = "zigma_std_http", .module = std_http_mod },
                .{ .name = "aida_schema_guard", .module = schema_guard_mod },
            },
        }),
    });
    const run_aida_rest_server = b.addRunArtifact(aida_rest_server);
    const aida_rest_server_step = b.step(
        "run-aida-rest",
        "Apply migrations and serve the generated AIDA REST API",
    );
    aida_rest_server_step.dependOn(&run_aida_rest_server.step);
    const check_aida_rest_server_step = b.step(
        "check-aida-rest",
        "Compile the generated AIDA REST server without running it",
    );
    check_aida_rest_server_step.dependOn(&aida_rest_server.step);

    const schema_validator = b.addExecutable(.{
        .name = "postgres-schema-validator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/postgres_schema_validator.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida_postgres", .module = aida_postgres_mod },
                .{ .name = "zigma_postgres_libpq", .module = postgres_libpq_mod },
            },
        }),
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/aida_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_mod },
                .{ .name = "aida", .module = aida_mod },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);

    const model_test_step = b.step("test-model", "Test normalized contract metadata and generated model types");
    for ([_][]const u8{
        "model_nullability_test.zig",
        "system_model_test.zig",
        "aida_nullable_test.zig",
        "model_consumers_test.zig",
        "aida_schema_reference_test.zig",
    }) |file| {
        const model_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("test/{s}", .{file})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zigma", .module = zigma_mod },
                    .{ .name = "aida", .module = aida_mod },
                    .{ .name = "aida_postgres", .module = aida_postgres_mod },
                    .{ .name = "zigma_rest", .module = rest_mod },
                    .{ .name = "zigma_postgres_ddl", .module = postgres_ddl_mod },
                    .{ .name = "zigma_postgres_migrations", .module = postgres_migrations_mod },
                    .{ .name = "zigma_postgres_crud", .module = postgres_crud_mod },
                },
            }),
        });
        const run_model_tests = b.addRunArtifact(model_tests);
        model_test_step.dependOn(&run_model_tests.step);
    }

    const postgres_ddl_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/postgres_ddl_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_mod },
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "zigma_postgres_ddl", .module = postgres_ddl_mod },
            },
        }),
    });
    const run_postgres_ddl_tests = b.addRunArtifact(postgres_ddl_tests);

    const postgres_executor_ddl_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/postgres_executor_ddl_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_mod },
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "zigma_postgres_ddl", .module = postgres_ddl_mod },
                .{ .name = "zigma_postgres_executor_ddl", .module = postgres_executor_ddl_mod },
            },
        }),
    });
    const run_postgres_executor_ddl_tests = b.addRunArtifact(postgres_executor_ddl_tests);

    const postgres_migrations_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/postgres_migrations_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_mod },
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "zigma_postgres_ddl", .module = postgres_ddl_mod },
                .{ .name = "zigma_postgres_migrations", .module = postgres_migrations_mod },
            },
        }),
    });
    const run_postgres_migrations_tests = b.addRunArtifact(postgres_migrations_tests);

    const postgres_migration_tool_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/postgres_migration_tool.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida_postgres", .module = aida_postgres_mod },
                .{ .name = "zigma_postgres_migrations", .module = postgres_migrations_mod },
            },
        }),
    });
    const run_postgres_migration_tool_tests = b.addRunArtifact(postgres_migration_tool_tests);

    const liquibase_runner_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/liquibase_runner_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma_liquibase_runner", .module = liquibase_runner_mod },
            },
        }),
    });
    const run_liquibase_runner_tests = b.addRunArtifact(liquibase_runner_tests);
    inline for (.{
        "LIQUIBASE_BIN",
        "LIQUIBASE_CHANGELOG",
        "LIQUIBASE_PASSWORD",
        "LIQUIBASE_SCHEMA",
        "LIQUIBASE_URL",
        "LIQUIBASE_USERNAME",
    }) |application_variable| {
        run_liquibase_runner_tests.setEnvironmentVariable(application_variable, "must-not-reach-liquibase");
    }

    const rest_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/rest_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_mod },
                .{ .name = "zigma_rest", .module = rest_mod },
            },
        }),
    });
    const run_rest_tests = b.addRunArtifact(rest_tests);

    const postgres_crud_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/postgres_crud_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_mod },
                .{ .name = "zigma_rest", .module = rest_mod },
                .{ .name = "zigma_postgres_crud", .module = postgres_crud_mod },
            },
        }),
    });
    const run_postgres_crud_tests = b.addRunArtifact(postgres_crud_tests);

    const aida_rest_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/aida_rest_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida_rest", .module = aida_rest_mod },
                .{ .name = "zigma_rest", .module = rest_mod },
            },
        }),
    });
    const run_aida_rest_tests = b.addRunArtifact(aida_rest_tests);

    const json_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/json_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_mod },
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "zigma_json", .module = zigma_json_mod },
            },
        }),
    });
    const run_json_tests = b.addRunArtifact(json_tests);

    const test_step = b.step("test", "Run tests (runtime and expected compile errors)");
    test_step.dependOn(model_test_step);
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_json_tests.step);
    test_step.dependOn(&run_postgres_ddl_tests.step);
    test_step.dependOn(&run_postgres_executor_ddl_tests.step);
    test_step.dependOn(&run_postgres_migrations_tests.step);
    test_step.dependOn(&run_postgres_migration_tool_tests.step);
    test_step.dependOn(&run_liquibase_runner_tests.step);
    test_step.dependOn(&run_rest_tests.step);
    test_step.dependOn(&run_postgres_crud_tests.step);
    test_step.dependOn(&run_aida_rest_tests.step);
    test_step.dependOn(&schema_guard.step);
    test_step.dependOn(&run_schema_check.step);

    const postgres_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/postgres_integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_mod },
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "zigma_postgres_ddl", .module = postgres_ddl_mod },
                .{ .name = "zigma_postgres_executor_ddl", .module = postgres_executor_ddl_mod },
                .{ .name = "zigma_postgres_libpq", .module = postgres_libpq_mod },
            },
        }),
    });

    const postgres_bootstrap = b.addExecutable(.{
        .name = "postgres-bootstrap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/postgres_bootstrap.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_mod },
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "zigma_postgres_ddl", .module = postgres_ddl_mod },
                .{ .name = "zigma_postgres_executor_ddl", .module = postgres_executor_ddl_mod },
                .{ .name = "zigma_postgres_libpq", .module = postgres_libpq_mod },
                .{ .name = "aida_schema_guard", .module = schema_guard_mod },
            },
        }),
    });
    const run_postgres_bootstrap = b.addRunArtifact(postgres_bootstrap);
    const postgres_bootstrap_step = b.step(
        "run-postgres-bootstrap",
        "Apply the compile-time AIDA schema using DATABASE_URL",
    );
    postgres_bootstrap_step.dependOn(&run_postgres_bootstrap.step);

    const rest_integration_server = b.addExecutable(.{
        .name = "rest-integration-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration/rest_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "aida_rest", .module = aida_rest_mod },
                .{ .name = "zigma_postgres_crud", .module = postgres_crud_mod },
                .{ .name = "zigma_postgres_libpq", .module = postgres_libpq_mod },
                .{ .name = "zigma_std_http", .module = std_http_mod },
            },
        }),
    });

    const postgres_liquibase_bootstrap = b.addExecutable(.{
        .name = "postgres-liquibase-bootstrap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/postgres_liquibase_bootstrap.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma_liquibase_runner", .module = liquibase_runner_mod },
                .{ .name = "aida_schema_guard", .module = schema_guard_mod },
            },
        }),
    });
    const run_postgres_liquibase_bootstrap = b.addRunArtifact(postgres_liquibase_bootstrap);
    const postgres_liquibase_bootstrap_step = b.step(
        "run-postgres-liquibase-bootstrap",
        "Apply accepted AIDA migrations using the external Liquibase CLI",
    );
    postgres_liquibase_bootstrap_step.dependOn(&run_postgres_liquibase_bootstrap.step);

    const run_postgres_integration = b.addSystemCommand(&.{"sh"});
    run_postgres_integration.addFileArg(b.path("test/integration/run_postgres.sh"));
    run_postgres_integration.addArtifactArg(postgres_integration_tests);
    run_postgres_integration.addArtifactArg(postgres_bootstrap);
    run_postgres_integration.addArtifactArg(schema_validator);

    const postgres_test_step = b.step("test-postgres", "Run integration tests against disposable PostgreSQL");
    postgres_test_step.dependOn(&run_postgres_integration.step);

    const run_rest_postgres_integration = b.addSystemCommand(&.{"sh"});
    run_rest_postgres_integration.addFileArg(b.path("test/integration/run_rest_postgres.sh"));
    run_rest_postgres_integration.addArtifactArg(postgres_bootstrap);
    run_rest_postgres_integration.addArtifactArg(rest_integration_server);
    const rest_postgres_test_step = b.step(
        "test-rest-postgres",
        "Run generated REST CRUD tests against disposable PostgreSQL",
    );
    rest_postgres_test_step.dependOn(&run_rest_postgres_integration.step);

    const liquibase_bin = b.option([]const u8, "liquibase-bin", "Path to the pinned Liquibase 5.0.4 CLI") orelse "liquibase";

    const accept_migration = b.addSystemCommand(&.{"sh"});
    accept_migration.addFileArg(b.path("tools/accept_migration.sh"));
    accept_migration.addArtifactArg(migration_tool);
    accept_migration.addArtifactArg(schema_validator);
    accept_migration.addArg(liquibase_bin);
    accept_migration.addDirectoryArg(b.path("."));
    const accept_migration_step = b.step("accept-migration", "Verify the draft in disposable PostgreSQL, then accept it");
    accept_migration_step.dependOn(&accept_migration.step);

    const baseline_existing = b.addSystemCommand(&.{"sh"});
    baseline_existing.addFileArg(b.path("tools/baseline_existing.sh"));
    baseline_existing.addArtifactArg(schema_validator);
    baseline_existing.addArg(liquibase_bin);
    baseline_existing.addDirectoryArg(b.path("."));
    const baseline_existing_step = b.step("baseline-existing", "Validate an existing bootstrap schema, then mark the initial baseline");
    baseline_existing_step.dependOn(&baseline_existing.step);

    const run_migration_tests = b.addSystemCommand(&.{"sh"});
    run_migration_tests.addFileArg(b.path("test/integration/run_migrations.sh"));
    run_migration_tests.addArtifactArg(schema_validator);
    run_migration_tests.addArtifactArg(postgres_liquibase_bootstrap);
    run_migration_tests.addFileArg(b.path("tools/baseline_existing.sh"));
    run_migration_tests.addArg(liquibase_bin);
    run_migration_tests.addDirectoryArg(b.path("."));
    const migration_test_step = b.step("test-migrations", "Run Liquibase migration tests against disposable PostgreSQL");
    migration_test_step.dependOn(&run_migration_tests.step);

    for (compile_error_cases ++ model_compile_error_cases) |case| {
        const case_obj = b.addObject(.{
            .name = case.file[0 .. case.file.len - 4],
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("test/compile_errors/{s}", .{case.file})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zigma", .module = zigma_mod },
                    .{ .name = "aida", .module = aida_mod },
                    .{ .name = "zigma_postgres_ddl", .module = postgres_ddl_mod },
                    .{ .name = "zigma_postgres_migrations", .module = postgres_migrations_mod },
                    .{ .name = "zigma_rest", .module = rest_mod },
                },
            }),
        });
        case_obj.expect_errors = .{ .contains = case.expected };
        test_step.dependOn(&case_obj.step);
        for (model_compile_error_cases) |model_case| {
            if (std.mem.eql(u8, case.file, model_case.file))
                model_test_step.dependOn(&case_obj.step);
        }
    }
}
