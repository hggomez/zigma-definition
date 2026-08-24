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

    const test_step = b.step("test", "Run tests (runtime and expected compile errors)");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_postgres_ddl_tests.step);
    test_step.dependOn(&run_postgres_executor_tests.step);

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
            },
        }),
    });
    const run_postgres_bootstrap = b.addRunArtifact(postgres_bootstrap);
    const postgres_bootstrap_step = b.step(
        "run-postgres-bootstrap",
        "Apply the compile-time AIDA schema using DATABASE_URL",
    );
    postgres_bootstrap_step.dependOn(&run_postgres_bootstrap.step);

    const run_postgres_integration = b.addSystemCommand(&.{"sh"});
    run_postgres_integration.addFileArg(b.path("test/integration/run_postgres.sh"));
    run_postgres_integration.addArtifactArg(postgres_integration_tests);
    run_postgres_integration.addArtifactArg(postgres_bootstrap);

    const postgres_test_step = b.step("test-postgres", "Run integration tests against disposable PostgreSQL");
    postgres_test_step.dependOn(&run_postgres_integration.step);

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
                },
            }),
        });
        case_obj.expect_errors = .{ .contains = case.expected };
        test_step.dependOn(&case_obj.step);
    }
}
