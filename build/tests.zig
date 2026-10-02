//! Suites locales y con servicios externos conectadas al mismo grafo de módulos.
//! Las integraciones son ramas separadas: test-local no necesita libpq, Docker,
//! PostgreSQL ni Liquibase. Cada helper declara una parte del grafo.

const std = @import("std");
const Modules = @import("modules.zig").Modules;
const AidaArtifacts = @import("aida.zig").Artifacts;

pub fn addSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    modules: Modules,
    aida: AidaArtifacts,
    liquibase_bin: []const u8,
) void {
    const unit = addUnitTests(b, target, optimize, modules, aida);
    addCompileErrors(b, target, optimize, modules, unit);
    const launcher = addLauncherTests(b, aida);
    addLocalTests(b, target, optimize, unit.all, launcher);
    addPostgresTests(b, target, optimize, modules, aida, liquibase_bin);
}

const UnitSteps = struct { all: *std.Build.Step, model: *std.Build.Step };

// addTest declara la compilación de tests; addRunArtifact agrega su ejecución.
// Este helper comparte esa mecánica; cada suite declara sus imports explícitos.
fn addTestRun(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    source: []const u8,
    imports: []const std.Build.Module.Import,
) *std.Build.Step.Run {
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path(source),
        .target = target,
        .optimize = optimize,
        .imports = imports,
    }) });
    return b.addRunArtifact(tests);
}

fn addUnitTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, modules: Modules, aida: AidaArtifacts) UnitSteps {
    const run_tests = addTestRun(b, target, optimize, "test/aida_test.zig", &.{
        .{ .name = "zigma", .module = modules.zigma },
        .{ .name = "aida", .module = modules.aida },
    });

    const model_test_step = b.step("test-model", "Test normalized contract metadata and generated model types");
    for ([_][]const u8{
        "model_nullability_test.zig",
        "system_model_test.zig",
        "aida_nullable_test.zig",
        "model_consumers_test.zig",
        "aida_schema_reference_test.zig",
    }) |file| {
        const run_model_tests = addTestRun(b, target, optimize, b.fmt("test/{s}", .{file}), &.{
            .{ .name = "zigma", .module = modules.zigma },
            .{ .name = "aida", .module = modules.aida },
            .{ .name = "aida_postgres", .module = modules.aida_postgres },
            .{ .name = "zigma_rest", .module = modules.rest },
            .{ .name = "zigma_postgres_ddl", .module = modules.postgres_ddl },
            .{ .name = "zigma_postgres_migrations", .module = modules.postgres_migrations },
            .{ .name = "zigma_postgres_crud", .module = modules.postgres_crud },
        });
        model_test_step.dependOn(&run_model_tests.step);
    }

    const run_postgres_ddl_tests = addTestRun(b, target, optimize, "test/postgres_ddl_test.zig", &.{
        .{ .name = "zigma", .module = modules.zigma },
        .{ .name = "aida", .module = modules.aida },
        .{ .name = "zigma_postgres_ddl", .module = modules.postgres_ddl },
    });

    const run_postgres_executor_ddl_tests = addTestRun(b, target, optimize, "test/postgres_executor_ddl_test.zig", &.{
        .{ .name = "zigma", .module = modules.zigma },
        .{ .name = "aida", .module = modules.aida },
        .{ .name = "zigma_postgres_ddl", .module = modules.postgres_ddl },
        .{ .name = "zigma_postgres_executor_ddl", .module = modules.postgres_executor_ddl },
    });

    const run_postgres_migrations_tests = addTestRun(b, target, optimize, "test/postgres_migrations_test.zig", &.{
        .{ .name = "zigma", .module = modules.zigma },
        .{ .name = "aida", .module = modules.aida },
        .{ .name = "zigma_postgres_ddl", .module = modules.postgres_ddl },
        .{ .name = "zigma_postgres_migrations", .module = modules.postgres_migrations },
    });

    const run_postgres_migration_tool_tests = addTestRun(b, target, optimize, "tools/postgres_migration_tool.zig", &.{
        .{ .name = "aida_postgres", .module = modules.aida_postgres },
        .{ .name = "zigma_postgres_migrations", .module = modules.postgres_migrations },
    });

    const run_liquibase_runner_tests = addTestRun(b, target, optimize, "test/liquibase_runner_test.zig", &.{
        .{ .name = "zigma_liquibase_runner", .module = modules.liquibase_runner },
    });
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

    const run_rest_tests = addTestRun(b, target, optimize, "test/rest_test.zig", &.{
        .{ .name = "zigma", .module = modules.zigma },
        .{ .name = "zigma_rest", .module = modules.rest },
    });

    const run_postgres_crud_tests = addTestRun(b, target, optimize, "test/postgres_crud_test.zig", &.{
        .{ .name = "zigma", .module = modules.zigma },
        .{ .name = "zigma_rest", .module = modules.rest },
        .{ .name = "zigma_postgres_crud", .module = modules.postgres_crud },
    });

    const run_aida_rest_tests = addTestRun(b, target, optimize, "test/aida_rest_test.zig", &.{
        .{ .name = "aida_rest", .module = modules.aida_rest },
        .{ .name = "zigma_rest", .module = modules.rest },
    });

    const run_json_tests = addTestRun(b, target, optimize, "test/json_test.zig", &.{
        .{ .name = "zigma", .module = modules.zigma },
        .{ .name = "aida", .module = modules.aida },
        .{ .name = "zigma_json", .module = modules.json },
    });
    const run_json_model_tests = addTestRun(b, target, optimize, "test/json_model_test.zig", &.{
        .{ .name = "zigma", .module = modules.zigma },
        .{ .name = "aida", .module = modules.aida },
        .{ .name = "zigma_json", .module = modules.json },
    });
    const test_json_step = b.step("test-json", "Probar serialización JSON y catálogo del modelo normalizado");
    test_json_step.dependOn(&run_json_tests.step);
    test_json_step.dependOn(&run_json_model_tests.step);

    const test_step = b.step("test", "Run tests (runtime and expected compile errors)");
    test_step.dependOn(model_test_step);
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(test_json_step);
    test_step.dependOn(&run_postgres_ddl_tests.step);
    test_step.dependOn(&run_postgres_executor_ddl_tests.step);
    test_step.dependOn(&run_postgres_migrations_tests.step);
    test_step.dependOn(&run_postgres_migration_tool_tests.step);
    test_step.dependOn(&run_liquibase_runner_tests.step);
    test_step.dependOn(&run_rest_tests.step);
    test_step.dependOn(&run_postgres_crud_tests.step);
    test_step.dependOn(&run_aida_rest_tests.step);
    test_step.dependOn(&aida.schema_guard.step);
    test_step.dependOn(&aida.schema_check.step);

    return .{ .all = test_step, .model = model_test_step };
}

fn addLauncherTests(b: *std.Build, aida: AidaArtifacts) *std.Build.Step {
    const test_aida_launcher = b.addSystemCommand(&.{"python3"});
    test_aida_launcher.addFileArg(b.path("test/integration/run_aida_test.py"));
    test_aida_launcher.addArtifactArg(aida.launcher);
    const test_aida_launcher_step = b.step("test-aida-launcher", "Probar arranque, configuración y cierre conjunto (Python 3; sin PostgreSQL)");
    test_aida_launcher_step.dependOn(&test_aida_launcher.step);
    return test_aida_launcher_step;
}

fn addLocalTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, unit_tests: *std.Build.Step, launcher_tests: *std.Build.Step) void {
    // Reutiliza las suites del consumidor sin duplicar sus módulos ni fixtures.
    const test_aida_consumer = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test-backend", "test-frontend" });
    test_aida_consumer.addArg(b.fmt("-Dtarget={s}", .{target.query.zigTriple(b.allocator) catch @panic("OOM")}));
    test_aida_consumer.addArg(b.fmt("-Dcpu={s}", .{target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM")}));
    test_aida_consumer.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
    if (target.query.ofmt) |ofmt| test_aida_consumer.addArg(b.fmt("-Dofmt={s}", .{@tagName(ofmt)}));
    if (target.query.dynamic_linker) |linker| test_aida_consumer.addArg(b.fmt("-Ddynamic-linker={s}", .{linker.get() orelse ""}));
    test_aida_consumer.setCwd(b.path("examples/aida"));
    test_aida_consumer.has_side_effects = true;
    const test_local_step = b.step("test-local", "Probar Zig, frontend, backend en memoria y lanzador (Node y Python; sin PostgreSQL)");
    test_local_step.dependOn(unit_tests);
    test_local_step.dependOn(launcher_tests);
    test_local_step.dependOn(&test_aida_consumer.step);
    const test_build_commands = b.addSystemCommand(&.{"python3"});
    test_build_commands.addFileArg(b.path("test/integration/build_commands_test.py"));
    test_build_commands.addArg(b.graph.zig_exe);
    test_local_step.dependOn(&test_build_commands.step);
}

fn addPostgresTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, modules: Modules, aida: AidaArtifacts, liquibase_bin: []const u8) void {
    const postgres_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/postgres_integration_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma", .module = modules.zigma },
                .{ .name = "aida", .module = modules.aida },
                .{ .name = "zigma_postgres_ddl", .module = modules.postgres_ddl },
                .{ .name = "zigma_postgres_executor_ddl", .module = modules.postgres_executor_ddl },
                .{ .name = "zigma_postgres_libpq", .module = modules.postgres_libpq },
            },
        }),
    });

    const postgres_bootstrap = b.addExecutable(.{
        .name = "postgres-bootstrap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration/postgres_bootstrap.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida", .module = modules.aida },
                .{ .name = "aida_postgres", .module = modules.aida_postgres },
                .{ .name = "zigma_postgres_ddl", .module = modules.postgres_ddl },
                .{ .name = "zigma_postgres_executor_ddl", .module = modules.postgres_executor_ddl },
                .{ .name = "zigma_postgres_libpq", .module = modules.postgres_libpq },
                .{ .name = "aida_schema_guard", .module = aida.schema_guard.root_module },
            },
        }),
    });
    const rest_integration_server = b.addExecutable(.{
        .name = "rest-integration-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/integration/rest_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida", .module = modules.aida },
                .{ .name = "aida_rest", .module = modules.aida_rest },
                .{ .name = "zigma_postgres_crud", .module = modules.postgres_crud },
                .{ .name = "zigma_postgres_libpq", .module = modules.postgres_libpq },
                .{ .name = "zigma_std_http", .module = modules.std_http },
            },
        }),
    });

    const run_postgres_integration = b.addSystemCommand(&.{"sh"});
    run_postgres_integration.addFileArg(b.path("test/integration/run_postgres.sh"));
    run_postgres_integration.addArtifactArg(postgres_integration_tests);
    run_postgres_integration.addArtifactArg(postgres_bootstrap);
    run_postgres_integration.addArtifactArg(aida.schema_validator);

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

    const run_migration_tests = b.addSystemCommand(&.{"sh"});
    run_migration_tests.addFileArg(b.path("test/integration/run_migrations.sh"));
    run_migration_tests.addArtifactArg(aida.schema_validator);
    run_migration_tests.addArtifactArg(aida.migration_applier);
    run_migration_tests.addArg(liquibase_bin);
    run_migration_tests.addDirectoryArg(b.path("."));
    const migration_test_step = b.step("test-migrations", "Run Liquibase migration tests against disposable PostgreSQL");
    migration_test_step.dependOn(&run_migration_tests.step);
}

fn addCompileErrors(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, modules: Modules, steps: UnitSteps) void {
    for (compile_error_cases ++ model_compile_error_cases) |case| {
        const case_obj = b.addObject(.{
            .name = case.file[0 .. case.file.len - 4],
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("test/compile_errors/{s}", .{case.file})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zigma", .module = modules.zigma },
                    .{ .name = "aida", .module = modules.aida },
                    .{ .name = "zigma_postgres_ddl", .module = modules.postgres_ddl },
                    .{ .name = "zigma_postgres_migrations", .module = modules.postgres_migrations },
                    .{ .name = "zigma_rest", .module = modules.rest },
                },
            }),
        });
        case_obj.expect_errors = .{ .contains = case.expected };
        steps.all.dependOn(&case_obj.step);
        for (model_compile_error_cases) |model_case| {
            if (std.mem.eql(u8, case.file, model_case.file))
                steps.model.dependOn(&case_obj.step);
        }
    }
}

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

const compile_error_cases = [_]CompileErrorCase{
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
