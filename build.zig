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
    .{ .file = "sql_unknown_type_mapping.zig", .expected = "type 'text' has no SQL mapping" },
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

    const sql_generator_mod = b.addModule("sql_generator", .{
        .root_source_file = b.path("src/sql_generator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
        },
    });

    const ts_backend_generator_mod = b.addModule("ts_backend_generator", .{
        .root_source_file = b.path("src/ts_backend_generator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
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

    const sql_generator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/sql_generator_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_mod },
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "sql_generator", .module = sql_generator_mod },
            },
        }),
    });
    const run_sql_generator_tests = b.addRunArtifact(sql_generator_tests);

    const ts_backend_generator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/ts_backend_generator_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_mod },
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "ts_backend_generator", .module = ts_backend_generator_mod },
            },
        }),
    });
    const run_ts_backend_generator_tests = b.addRunArtifact(ts_backend_generator_tests);

    const print_schema_exe = b.addExecutable(.{
        .name = "print_schema",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/print_schema.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "sql_generator", .module = sql_generator_mod },
            },
        }),
    });
    const run_print_schema = b.addRunArtifact(print_schema_exe);
    const print_schema_step = b.step("print-schema", "Print the CREATE TABLE DDL generated for the aida system");
    print_schema_step.dependOn(&run_print_schema.step);

    // `zig build create-database`: starts the Postgres container (docker-compose.yml)
    // if it isn't running, waits for it to be ready (the `--wait` flag blocks on the
    // container's healthcheck, so this is race-free even on first-time init), and
    // pipes the generated aida schema into psql running inside that container. No
    // Postgres driver needed: psql runs inside the container, so the only host
    // dependency is Docker.
    const docker_up = b.addSystemCommand(&.{ "docker", "compose", "up", "-d", "--wait" });

    const run_print_schema_for_db = b.addRunArtifact(print_schema_exe);
    const aida_schema_sql = run_print_schema_for_db.captureStdOut(.{});

    const apply_aida_schema = b.addSystemCommand(&.{
        "docker", "exec", "-i", "zigma_aida_postgres",
        "psql",   "-U",   "aida", "-d", "aida",
    });
    apply_aida_schema.setStdIn(.{ .lazy_path = aida_schema_sql });
    apply_aida_schema.step.dependOn(&docker_up.step);

    const create_database_step = b.step("create-database", "Start Postgres via Docker, then generate and apply the aida schema");
    create_database_step.dependOn(&apply_aida_schema.step);

    // `zig build ts-backend`: generate the TypeScript DML module and its test
    // module from the aida SSOT, write both to zig-out/ts-backend/, then run
    // the generated tests with `node --test`. Node 22.18+ runs .ts directly
    // and the generated tests only use node:test / node:assert, so there is
    // no npm step.
    const print_ts_backend_exe = b.addExecutable(.{
        .name = "print_ts_backend",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/print_ts_backend.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "ts_backend_generator", .module = ts_backend_generator_mod },
            },
        }),
    });
    const print_ts_backend_tests_exe = b.addExecutable(.{
        .name = "print_ts_backend_tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/print_ts_backend_tests.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "ts_backend_generator", .module = ts_backend_generator_mod },
            },
        }),
    });

    const dml_ts = b.addRunArtifact(print_ts_backend_exe).captureStdOut(.{});
    const dml_test_ts = b.addRunArtifact(print_ts_backend_tests_exe).captureStdOut(.{});

    // The generated files are written into the committed backend/ package
    // (gitignored there) so the hand-written integration test can import
    // ./dml.ts and Node resolves it.
    const write_ts_backend = b.addUpdateSourceFiles();
    write_ts_backend.addCopyFileToSource(dml_ts, "backend/src/dml.ts");
    write_ts_backend.addCopyFileToSource(dml_test_ts, "backend/src/dml.test.ts");

    const run_ts_backend_node_tests = b.addSystemCommand(&.{ "node", "--test", "src/dml.test.ts" });
    run_ts_backend_node_tests.setCwd(b.path("backend"));
    run_ts_backend_node_tests.step.dependOn(&write_ts_backend.step);

    const ts_backend_step = b.step("ts-backend", "Generate the aida TypeScript DML module + tests into backend/, then run the pure tests with node");
    ts_backend_step.dependOn(&run_ts_backend_node_tests.step);

    // `zig build ts-backend-db`: the same generation, then run the DML
    // integration tests against the docker-compose Postgres (schema applied by
    // the same steps as `create-database`). Needs Docker and `pg` in
    // backend/node_modules (npm install runs first).
    const npm = if (@import("builtin").os.tag == .windows) "npm.cmd" else "npm";
    const npm_install = b.addSystemCommand(&.{ npm, "install", "--no-audit", "--no-fund" });
    npm_install.setCwd(b.path("backend"));

    const run_ts_backend_db_tests = b.addSystemCommand(&.{ "node", "--test", "src/dml.integration.test.ts" });
    run_ts_backend_db_tests.setCwd(b.path("backend"));
    run_ts_backend_db_tests.step.dependOn(&write_ts_backend.step);
    run_ts_backend_db_tests.step.dependOn(&npm_install.step);
    run_ts_backend_db_tests.step.dependOn(&apply_aida_schema.step);

    const ts_backend_db_step = b.step("ts-backend-db", "Generate, then run the DML integration tests against the docker-compose Postgres");
    ts_backend_db_step.dependOn(&run_ts_backend_db_tests.step);

    const test_step = b.step("test", "Run tests (runtime and expected compile errors)");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_sql_generator_tests.step);
    test_step.dependOn(&run_ts_backend_generator_tests.step);

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
                    .{ .name = "sql_generator", .module = sql_generator_mod },
                },
            }),
        });
        case_obj.expect_errors = .{ .contains = case.expected };
        test_step.dependOn(&case_obj.step);
    }
}
