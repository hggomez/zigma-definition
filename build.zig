const std = @import("std");

/// The error must be AT the marked expression of this fragment: its path, as
/// the compiler prints it, is the start of the error line. Used for the native
/// compiler messages, whose tail is not stable (it can end in the mangled name
/// of an anonymous struct) and cannot be matched verbatim. The separator is
/// the one of the host (`/` on posix, `\` on windows), which is how the
/// compiler prints it, so the cases match on either system; it is a comptime
/// constant, so the whole path is concatenated at compile time.
fn at(comptime file: []const u8) []const u8 {
    const sep = std.fs.path.sep_str;
    return "test" ++ sep ++ "compile_errors" ++ sep ++ file ++ ":/?/";
}

/// Expected-compile-error cases: each file in test/compile_errors must FAIL
/// to compile with a matching error (see Step.Compile.expect_errors). The
/// match is per line: a plain string must be the END of some error line; with
/// the /?/ wildcard the text before it must be the start of the line and the
/// text after it the end (only the first /?/ of the line is a wildcard, and
/// there is no regex: those two forms are the whole vocabulary). For the
/// messages of the framework, which are ours and therefore stable, the full
/// message is used; for the native ones, `at` (see above).
const compile_error_cases = [_]struct { file: []const u8, expected: []const u8 }{
    .{ .file = "types_not_a_typedef.zig", .expected = "type 'text': must be a TypeDef (like zigma.TypeDef{ .Type = i64 })" },
    .{ .file = "types_extra_property.zig", .expected = "type 'fecha': must be a TypeDef (like zigma.TypeDef{ .Type = i64 })" },
    .{ .file = "record_unknown_type.zig", .expected = "unknown type 'inexistente'" },
    .{ .file = "record_unknown_property.zig", .expected = "unknown property 'colour'" },
    .{ .file = "record_is_name_false.zig", .expected = "is_name only admits true in a definition (false is the default)" },
    .{ .file = "instance_wrong_value_type.zig", .expected = "expected type 'i64', found '*const [6:0]u8'" },
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
    .{ .file = "defined_type_wrong_field_type.zig", .expected = "expected type 'i64', found '*const [1:0]u8'" },
    .{ .file = "validar_cargo_missing_field.zig", .expected = at("validar_cargo_missing_field.zig") },
    .{ .file = "defined_type_no_field.zig", .expected = at("defined_type_no_field.zig") },
    .{ .file = "postgres_ddl_mapping_missing.zig", .expected = "entity 'clases', field 'fecha': missing PostgreSQL type mapping for domain type 'fecha'" },
    .{ .file = "postgres_ddl_mapping_invalid.zig", .expected = "PostgreSQL type mapping 'text': 'sql_type' must be a non-empty string" },
    .{ .file = "postgres_ddl_unknown_table.zig", .expected = "PostgreSQL DDL: unknown entity 'inexistentes'" },
    .{ .file = "postgres_ddl_identifier_too_long.zig", .expected = "PostgreSQL identifier 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' exceeds 63 bytes" },
    .{ .file = "postgres_ddl_fk_cycle.zig", .expected = "PostgreSQL DDL: foreign key cycle involving entity 'lefts' cannot be generated with inline constraints" },
    .{ .file = "postgres_migrations_snapshot_stale.zig", .expected = "PostgreSQL schema differs from db/schema.snapshot.json; run 'zig build migration -Dname=<name>'" },
    .{ .file = "rest_codec_missing.zig", .expected = "entity 'events', field 'when': missing REST codec for domain type 'fecha'" },
    .{ .file = "rest_codec_invalid.zig", .expected = "REST codec 'text': must be a zigma_rest.Codec" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigma_mod = b.addModule("zigma", .{
        .root_source_file = b.path("src/zigma.zig"),
        .target = target,
        .optimize = optimize,
    });

    const aida_mod = b.addModule("aida", .{
        .root_source_file = b.path("examples/aida.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
        },
    });

    const rest_mod = b.addModule("zigma_rest", .{
        .root_source_file = b.path("src/rest.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
        },
    });

    const postgres_crud_mod = b.addModule("zigma_postgres_crud", .{
        .root_source_file = b.path("src/postgres_crud.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
            .{ .name = "zigma_rest", .module = rest_mod },
        },
    });

    const std_http_mod = b.addModule("zigma_std_http", .{
        .root_source_file = b.path("src/std_http.zig"),
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
        .root_source_file = b.path("src/postgres_ddl.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
        },
    });

    const postgres_executor_mod = b.addModule("zigma_postgres_executor", .{
        .root_source_file = b.path("src/postgres_executor.zig"),
        .target = target,
        .optimize = optimize,
    });

    const postgres_migrations_mod = b.addModule("zigma_postgres_migrations", .{
        .root_source_file = b.path("src/postgres_migrations.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
            .{ .name = "zigma_postgres_ddl", .module = postgres_ddl_mod },
        },
    });

    const liquibase_runner_mod = b.addModule("zigma_liquibase_runner", .{
        .root_source_file = b.path("src/liquibase_runner.zig"),
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
    if (b.option([]const u8, "name", "Migration name using letters, digits, and underscores")) |name|
        run_create_migration.addArg(name);
    const migration_step = b.step("migration", "Create a Liquibase SQL draft for the current entity changes");
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
        "Prefix containing the libpq include/ and lib/ directories",
    );
    const postgres_libpq_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/postgres_libpq.h"),
        .target = target,
        .optimize = optimize,
    });
    if (libpq_prefix) |prefix| {
        postgres_libpq_translate.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "include" }) });
    }
    const postgres_libpq_bindings_mod = postgres_libpq_translate.createModule();
    postgres_libpq_bindings_mod.linkSystemLibrary("pq", .{});
    if (libpq_prefix) |prefix| {
        postgres_libpq_bindings_mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ prefix, "lib" }) });
    }

    const postgres_libpq_mod = b.addModule("zigma_postgres_libpq", .{
        .root_source_file = b.path("src/postgres_libpq.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma_postgres_executor", .module = postgres_executor_mod },
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

    const postgres_executor_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/postgres_executor_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_mod },
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "zigma_postgres_ddl", .module = postgres_ddl_mod },
                .{ .name = "zigma_postgres_executor", .module = postgres_executor_mod },
            },
        }),
    });
    const run_postgres_executor_tests = b.addRunArtifact(postgres_executor_tests);

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
            },
        }),
    });
    const run_aida_rest_tests = b.addRunArtifact(aida_rest_tests);

    const test_step = b.step("test", "Run tests (runtime and expected compile errors)");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_postgres_ddl_tests.step);
    test_step.dependOn(&run_postgres_executor_tests.step);
    test_step.dependOn(&run_postgres_migrations_tests.step);
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
                .{ .name = "zigma_postgres_executor", .module = postgres_executor_mod },
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
                .{ .name = "zigma_postgres_executor", .module = postgres_executor_mod },
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
    accept_migration.addFileArg(b.path("test/integration/accept_migration.sh"));
    accept_migration.addArtifactArg(migration_tool);
    accept_migration.addArtifactArg(schema_validator);
    accept_migration.addArg(liquibase_bin);
    accept_migration.addDirectoryArg(b.path("."));
    const accept_migration_step = b.step("accept-migration", "Verify the draft in disposable PostgreSQL, then accept it");
    accept_migration_step.dependOn(&accept_migration.step);

    const baseline_existing = b.addSystemCommand(&.{"sh"});
    baseline_existing.addFileArg(b.path("test/integration/baseline_existing.sh"));
    baseline_existing.addArtifactArg(schema_validator);
    baseline_existing.addArg(liquibase_bin);
    baseline_existing.addDirectoryArg(b.path("."));
    const baseline_existing_step = b.step("baseline-existing", "Validate an existing bootstrap schema, then mark the initial baseline");
    baseline_existing_step.dependOn(&baseline_existing.step);

    const run_migration_tests = b.addSystemCommand(&.{"sh"});
    run_migration_tests.addFileArg(b.path("test/integration/run_migrations.sh"));
    run_migration_tests.addArtifactArg(schema_validator);
    run_migration_tests.addArtifactArg(postgres_liquibase_bootstrap);
    run_migration_tests.addFileArg(b.path("test/integration/baseline_existing.sh"));
    run_migration_tests.addArg(liquibase_bin);
    run_migration_tests.addDirectoryArg(b.path("."));
    const migration_test_step = b.step("test-migrations", "Run Liquibase migration tests against disposable PostgreSQL");
    migration_test_step.dependOn(&run_migration_tests.step);

    for (compile_error_cases) |case| {
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
    }
}
