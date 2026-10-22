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
    .{ .file = "sql_type_not_in_type_defs.zig", .expected = "type 'fecha' is not in type_defs" },
    .{ .file = "zig_type_map_ts_float.zig", .expected = "Zig type 'f32' has no TS mapping" },
    .{ .file = "zig_type_map_ts_optional.zig", .expected = "Zig type '?u8' has no TS mapping" },
    .{ .file = "zig_type_map_ts_other_slice.zig", .expected = "Zig type '[]const i32' has no TS mapping" },
    .{ .file = "zig_type_map_ts_struct_field_unsupported.zig", .expected = "Zig type 'f64' has no TS mapping" },
    .{ .file = "ts_type_not_in_type_defs.zig", .expected = "type 'fecha' is not in type_defs" },
    .{ .file = "zig_type_map_sql_too_wide.zig", .expected = "Zig type 'u64' does not fit in a Postgres BIGINT" },
    .{ .file = "zig_type_map_sql_too_wide_signed.zig", .expected = "Zig type 'i65' does not fit in a Postgres BIGINT" },
    .{ .file = "zig_type_map_sql_float.zig", .expected = "Zig type 'f32' has no SQL mapping" },
    .{ .file = "zig_type_map_sql_optional.zig", .expected = "Zig type '?u8' has no SQL mapping" },
    .{ .file = "zig_type_map_sql_other_slice.zig", .expected = "Zig type '[]const i32' has no SQL mapping" },
    .{ .file = "zig_type_map_sql_nested_struct.zig", .expected = "field 'desde' is a struct: nested structs have no SQL mapping yet" },
    .{ .file = "zig_type_map_sql_struct_field_unsupported.zig", .expected = "Zig type 'f64' has no SQL mapping" },
    .{ .file = "rules_not_a_struct.zig", .expected = "a rule collection must be a struct of rule definitions" },
    .{ .file = "rules_not_a_rule_definition.zig", .expected = "rule 'checkBooking': a rule definition must be a struct like .{ .record = ..., .rule = ... }" },
    .{ .file = "rules_missing_record.zig", .expected = "rule 'checkBooking': missing 'record'" },
    .{ .file = "rules_missing_rule.zig", .expected = "rule 'checkBooking': missing 'rule'" },
    .{ .file = "rules_unknown_property.zig", .expected = "rule 'checkBooking': unknown property 'colour'" },
    .{ .file = "rules_not_a_function.zig", .expected = "rule 'checkBooking': 'rule' must be a function" },
    .{ .file = "rules_two_parameters.zig", .expected = "rule 'checkBooking': must take exactly one parameter, an instance of its record" },
    .{ .file = "rules_parameter_of_other_record.zig", .expected = "rule 'checkBooking': its parameter must be the instance type of its record" },
    .{ .file = "rules_not_a_validation.zig", .expected = "rule 'checkBooking': must be a validation, returning error{...}!void" },
    .{ .file = "rules_returns_a_value.zig", .expected = "rule 'checkBooking': must be a validation, returning error{...}!void" },
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

    const zig_type_map_sql_mod = b.addModule("zig_type_map_sql", .{
        .root_source_file = b.path("src/zig_type_map_sql.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sql_generator_mod = b.addModule("sql_generator", .{
        .root_source_file = b.path("src/sql_generator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
            .{ .name = "zig_type_map_sql", .module = zig_type_map_sql_mod },
        },
    });

    const zig_type_map_ts_mod = b.addModule("zig_type_map_ts", .{
        .root_source_file = b.path("src/zig_type_map_ts.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ts_backend_generator_mod = b.addModule("ts_backend_generator", .{
        .root_source_file = b.path("src/ts_backend_generator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
            .{ .name = "zig_type_map_ts", .module = zig_type_map_ts_mod },
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

    const sql_generator_aida_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/sql_generator_aida_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "sql_generator", .module = sql_generator_mod },
            },
        }),
    });
    const run_sql_generator_aida_tests = b.addRunArtifact(sql_generator_aida_tests);

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

    const zig_type_map_ts_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/zig_type_map_ts_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "zig_type_map_ts", .module = zig_type_map_ts_mod },
            },
        }),
    });
    const run_zig_type_map_ts_tests = b.addRunArtifact(zig_type_map_ts_tests);

    const zig_type_map_sql_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/zig_type_map_sql_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zig_type_map_sql", .module = zig_type_map_sql_mod },
            },
        }),
    });
    const run_zig_type_map_sql_tests = b.addRunArtifact(zig_type_map_sql_tests);

    // A small system of its own with rules (rooms and bookings), for the
    // tests of defineRules and of the rules WASM module.
    const test_system_mod = b.createModule(.{
        .root_source_file = b.path("test/test_system.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
        },
    });

    const rules_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/rules_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_mod },
                .{ .name = "test_system", .module = test_system_mod },
            },
        }),
    });
    const run_rules_tests = b.addRunArtifact(rules_tests);

    // The rules WASM module is generic: it exports the rules of whatever
    // module it is given as "system". Here, the test system.
    const rules_wasm_test_system_mod = b.createModule(.{
        .root_source_file = b.path("src/rules_wasm.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "system", .module = test_system_mod },
        },
    });
    const rules_wasm_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/rules_wasm_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "rules_wasm", .module = rules_wasm_test_system_mod },
            },
        }),
    });
    const run_rules_wasm_tests = b.addRunArtifact(rules_wasm_tests);

    const ts_rules_generator_mod = b.addModule("ts_rules_generator", .{
        .root_source_file = b.path("src/ts_rules_generator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig_type_map_ts", .module = zig_type_map_ts_mod },
            .{ .name = "ts_backend_generator", .module = ts_backend_generator_mod },
        },
    });
    const ts_rules_generator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/ts_rules_generator_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_mod },
                .{ .name = "test_system", .module = test_system_mod },
                .{ .name = "ts_rules_generator", .module = ts_rules_generator_mod },
            },
        }),
    });
    const run_ts_rules_generator_tests = b.addRunArtifact(ts_rules_generator_tests);

    const ts_server_generator_mod = b.addModule("ts_server_generator", .{
        .root_source_file = b.path("src/ts_server_generator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_mod },
            .{ .name = "ts_backend_generator", .module = ts_backend_generator_mod },
        },
    });
    const ts_server_generator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/ts_server_generator_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "ts_server_generator", .module = ts_server_generator_mod },
            },
        }),
    });
    const run_ts_server_generator_tests = b.addRunArtifact(ts_server_generator_tests);

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
    // dependency is Docker. Only the `postgres` service: the `backend` one is
    // brought up by `http-docker`, once its server.ts is generated.
    const docker_up = b.addSystemCommand(&.{ "docker", "compose", "up", "-d", "--wait", "postgres" });

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

    // `zig build ts-backend-db`: bring up the container and apply the schema
    // (same steps as `create-database`), `npm install` in backend/, regenerate
    // dml.ts, then run test/db_backend_integration_test.zig - a Zig test that
    // drives the generated builders through Node against the real database.
    // Not on `test_step` (needs Docker + Node).
    const npm = if (@import("builtin").os.tag == .windows) "npm.cmd" else "npm";
    const npm_install = b.addSystemCommand(&.{ npm, "install", "--no-audit", "--no-fund" });
    npm_install.setCwd(b.path("backend"));

    const db_backend_integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/db_backend_integration_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_db_backend_integration_tests = b.addRunArtifact(db_backend_integration_tests);
    run_db_backend_integration_tests.has_side_effects = true;
    run_db_backend_integration_tests.step.dependOn(&write_ts_backend.step);
    run_db_backend_integration_tests.step.dependOn(&npm_install.step);
    run_db_backend_integration_tests.step.dependOn(&apply_aida_schema.step);

    const ts_backend_db_step = b.step("ts-backend-db", "Generate, then run the DML integration test against the docker-compose Postgres");
    ts_backend_db_step.dependOn(&run_db_backend_integration_tests.step);

    // `zig build backend-docker`: the backend in its own container. Regenerate
    // dml.ts into backend/ (generated on the host: no Zig in the image), apply
    // the aida schema, build the `backend` image, then run
    // test/backend_docker_test.zig - a Zig test that runs the generated
    // builders inside that container against the `postgres` service. Not on
    // `test_step` (needs Docker).
    const build_backend_image = b.addSystemCommand(&.{ "docker", "compose", "build", "backend" });
    build_backend_image.step.dependOn(&write_ts_backend.step);

    const backend_docker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/backend_docker_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_backend_docker_tests = b.addRunArtifact(backend_docker_tests);
    run_backend_docker_tests.has_side_effects = true;
    run_backend_docker_tests.step.dependOn(&build_backend_image.step);
    run_backend_docker_tests.step.dependOn(&apply_aida_schema.step);

    const backend_docker_step = b.step("backend-docker", "Build the backend image and run the generated DML inside it against the docker-compose Postgres");
    backend_docker_step.dependOn(&run_backend_docker_tests.step);

    // `zig build http-docker`: the generated HTTP server as the backend's
    // long-running process. Regenerate dml.ts + server.ts into backend/, apply
    // the aida schema, build the image, bring the backend up (waiting for its
    // healthcheck), then run test/http_docker_test.zig - a Zig test that
    // requests the API from the host. Not on `test_step` (needs Docker + Node).
    const print_ts_server_exe = b.addExecutable(.{
        .name = "print_ts_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/print_ts_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "ts_server_generator", .module = ts_server_generator_mod },
            },
        }),
    });
    const server_ts = b.addRunArtifact(print_ts_server_exe).captureStdOut(.{});
    const write_ts_server = b.addUpdateSourceFiles();
    write_ts_server.addCopyFileToSource(server_ts, "backend/src/server.ts");

    const build_backend_image_with_server = b.addSystemCommand(&.{ "docker", "compose", "build", "backend" });
    build_backend_image_with_server.step.dependOn(&write_ts_backend.step);
    build_backend_image_with_server.step.dependOn(&write_ts_server.step);

    const backend_up = b.addSystemCommand(&.{ "docker", "compose", "up", "-d", "--wait", "backend" });
    backend_up.step.dependOn(&build_backend_image_with_server.step);
    backend_up.step.dependOn(&apply_aida_schema.step);

    const http_docker_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/http_docker_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_http_docker_tests = b.addRunArtifact(http_docker_tests);
    run_http_docker_tests.has_side_effects = true;
    run_http_docker_tests.step.dependOn(&backend_up.step);

    const http_docker_step = b.step("http-docker", "Generate the HTTP server, run it in the backend container and request it from the host");
    http_docker_step.dependOn(&run_http_docker_tests.step);

    // `zig build rules-wasm`: compile the rules of the test system to one
    // wasm32 module (src/rules_wasm.zig with test/test_system.zig as its
    // "system") and run test/rules_wasm_node_test.zig, a Zig test that loads
    // it with Node's built-in WebAssembly and calls the rules under the
    // contract. Not on `test_step` (needs Node). The modules are created again
    // for wasm32: every module of a compilation shares its target.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const zigma_wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/zigma.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const test_system_wasm_mod = b.createModule(.{
        .root_source_file = b.path("test/test_system.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_wasm_mod },
        },
    });
    const test_system_rules_wasm = b.addExecutable(.{
        .name = "test_system_rules",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/rules_wasm.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "system", .module = test_system_wasm_mod },
            },
        }),
    });
    // a library of exports: no entry point, and the `export`s kept. rdynamic
    // also exports `__stack_pointer` (accepted, not contract); the exact list
    // (`export_symbol_names`) would repeat the rule names here.
    test_system_rules_wasm.entry = .disabled;
    test_system_rules_wasm.rdynamic = true;

    const rules_wasm_options = b.addOptions();
    rules_wasm_options.addOptionPath("wasm_path", test_system_rules_wasm.getEmittedBin());
    const rules_wasm_node_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/rules_wasm_node_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = rules_wasm_options.createModule() },
            },
        }),
    });
    const run_rules_wasm_node_tests = b.addRunArtifact(rules_wasm_node_tests);

    // Then the generated rules.ts of the test system, next to its compiled
    // rules as rules.wasm (rules.ts loads ./rules.wasm), in a generated
    // directory: test/rules_ts_node_test.zig imports it from Node.
    const print_test_system_rules_ts_exe = b.addExecutable(.{
        .name = "print_test_system_rules_ts",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/print_test_system_rules_ts.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "test_system", .module = test_system_mod },
                .{ .name = "ts_rules_generator", .module = ts_rules_generator_mod },
            },
        }),
    });
    const test_system_rules_ts = b.addRunArtifact(print_test_system_rules_ts_exe).captureStdOut(.{});
    const test_system_rules_dir = b.addWriteFiles();
    const test_system_rules_ts_path = test_system_rules_dir.addCopyFile(test_system_rules_ts, "rules.ts");
    _ = test_system_rules_dir.addCopyFile(test_system_rules_wasm.getEmittedBin(), "rules.wasm");

    const rules_ts_options = b.addOptions();
    // the path of rules.ts (an option path must be a file); rules.wasm is next to it
    rules_ts_options.addOptionPath("rules_ts_path", test_system_rules_ts_path);
    const rules_ts_node_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/rules_ts_node_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "build_options", .module = rules_ts_options.createModule() },
            },
        }),
    });
    const run_rules_ts_node_tests = b.addRunArtifact(rules_ts_node_tests);

    const rules_wasm_step = b.step("rules-wasm", "Compile the test system's rules to wasm32, generate its rules.ts, and test both from Node");
    rules_wasm_step.dependOn(&run_rules_wasm_node_tests.step);
    rules_wasm_step.dependOn(&run_rules_ts_node_tests.step);

    const test_step = b.step("test", "Run tests (runtime and expected compile errors)");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_sql_generator_tests.step);
    test_step.dependOn(&run_sql_generator_aida_tests.step);
    test_step.dependOn(&run_ts_backend_generator_tests.step);
    test_step.dependOn(&run_zig_type_map_ts_tests.step);
    test_step.dependOn(&run_zig_type_map_sql_tests.step);
    test_step.dependOn(&run_rules_tests.step);
    test_step.dependOn(&run_rules_wasm_tests.step);
    test_step.dependOn(&run_ts_rules_generator_tests.step);
    test_step.dependOn(&run_ts_server_generator_tests.step);

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
                    .{ .name = "zig_type_map_ts", .module = zig_type_map_ts_mod },
                    .{ .name = "ts_backend_generator", .module = ts_backend_generator_mod },
                    .{ .name = "zig_type_map_sql", .module = zig_type_map_sql_mod },
                },
            }),
        });
        case_obj.expect_errors = .{ .contains = case.expected };
        test_step.dependOn(&case_obj.step);
    }
}
