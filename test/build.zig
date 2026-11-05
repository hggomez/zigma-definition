//! The tests of the framework, with aida (examples/aida.zig) as their example
//! and test_system.zig for the rules. A package of its own (test/build.zig.zon,
//! depending on the root package), so that this build script is not in the
//! root's directory: two build scripts in one directory share a cached
//! runner, and the second one gets the first one's steps.
//!
//!   zig build --build-file test/build.zig test        (no Node, no Docker)
//!   zig build --build-file test/build.zig test-all    (test, then the rest)
//!
//! It reuses the pub functions of the root build.zig (the framework's
//! modules, the generator, the compose stacks), so the wiring is written
//! once. They get the root package's builder (`root`): its src/, examples/,
//! backend/, frontend/, .env and compose files. This one (`b`) owns the
//! tests in this directory.

const std = @import("std");
const instance = @import("zigma_definition");

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
    .{ .file = "ts_server_struct_text_field.zig", .expected = "field 'nombre' of type 'lugar': text inside a composite type is not read yet" },
};

const Import = std.Build.Module.Import;

/// A test of `source` with the named modules it imports, run.
fn addTestRun(b: *std.Build, source: []const u8, imports: []const Import, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Run {
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = target,
            .optimize = optimize,
            .imports = imports,
        }),
    });
    return b.addRunArtifact(t);
}

/// A test that drives a stack from the host (Docker): always rerun, from
/// the root (where `docker compose` finds the stack).
fn addStackTestRun(b: *std.Build, root: *std.Build, source: []const u8, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Run {
    const run = addTestRun(b, source, &.{}, target, optimize);
    run.setCwd(root.path("."));
    run.has_side_effects = true;
    return run;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const dep = b.dependency("zigma_definition", .{ .target = target, .optimize = optimize });
    const root = dep.builder;
    const fw = instance.frameworkOf(dep);

    // The example system of the tests.
    const aida_mod = instance.addSystemModule(root, fw, root.path("examples/aida.zig"), target, optimize);
    // A small system of its own with rules (rooms and bookings), for the
    // tests of defineRules and of the rules WASM module.
    const test_system_mod = instance.addSystemModule(b, fw, b.path("test_system.zig"), target, optimize);

    // `test`: the tests of the framework (runtime and expected
    // compile errors), no Node nor Docker.
    const test_step = b.step("test", "Run tests (runtime and expected compile errors)");
    const unit_tests = [_]struct { source: []const u8, imports: []const Import }{
        .{ .source = "zigma_test.zig", .imports = &.{
            .{ .name = "zigma", .module = fw.zigma },
            .{ .name = "aida", .module = aida_mod },
        } },
        .{ .source = "sql_generator_test.zig", .imports = &.{
            .{ .name = "zigma", .module = fw.zigma },
            .{ .name = "aida", .module = aida_mod },
            .{ .name = "sql_generator", .module = fw.sql_generator },
        } },
        .{ .source = "ts_backend_generator_test.zig", .imports = &.{
            .{ .name = "zigma", .module = fw.zigma },
            .{ .name = "aida", .module = aida_mod },
            .{ .name = "ts_backend_generator", .module = fw.ts_backend_generator },
        } },
        .{ .source = "zig_type_map_ts_test.zig", .imports = &.{
            .{ .name = "aida", .module = aida_mod },
            .{ .name = "zig_type_map_ts", .module = fw.zig_type_map_ts },
        } },
        .{ .source = "zig_type_map_sql_test.zig", .imports = &.{
            .{ .name = "zig_type_map_sql", .module = fw.zig_type_map_sql },
        } },
        .{ .source = "rules_test.zig", .imports = &.{
            .{ .name = "zigma", .module = fw.zigma },
            .{ .name = "test_system", .module = test_system_mod },
        } },
        .{ .source = "ts_rules_generator_test.zig", .imports = &.{
            .{ .name = "zigma", .module = fw.zigma },
            .{ .name = "test_system", .module = test_system_mod },
            .{ .name = "ts_rules_generator", .module = fw.ts_rules_generator },
        } },
        .{ .source = "ts_server_generator_test.zig", .imports = &.{
            .{ .name = "zigma", .module = fw.zigma },
            .{ .name = "aida", .module = aida_mod },
            .{ .name = "ts_server_generator", .module = fw.ts_server_generator },
        } },
        .{ .source = "frontend_generator_test.zig", .imports = &.{
            .{ .name = "aida", .module = aida_mod },
            .{ .name = "frontend_generator", .module = fw.frontend_generator },
        } },
    };
    for (unit_tests) |t| test_step.dependOn(&addTestRun(b, t.source, t.imports, target, optimize).step);

    // The rules WASM module is generic: it exports the rules of whatever
    // module it is given as "system". Here, the test system.
    const rules_wasm_test_system_mod = b.createModule(.{
        .root_source_file = root.path("src/rules_wasm.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "system", .module = test_system_mod },
        },
    });
    test_step.dependOn(&addTestRun(b, "rules_wasm_test.zig", &.{
        .{ .name = "rules_wasm", .module = rules_wasm_test_system_mod },
    }, target, optimize).step);

    for (compile_error_cases) |case| {
        const case_obj = b.addObject(.{
            .name = case.file[0 .. case.file.len - 4],
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("compile_errors/{s}", .{case.file})),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zigma", .module = fw.zigma },
                    .{ .name = "aida", .module = aida_mod },
                    .{ .name = "sql_generator", .module = fw.sql_generator },
                    .{ .name = "zig_type_map_ts", .module = fw.zig_type_map_ts },
                    .{ .name = "ts_backend_generator", .module = fw.ts_backend_generator },
                    .{ .name = "zig_type_map_sql", .module = fw.zig_type_map_sql },
                    .{ .name = "ts_server_generator", .module = fw.ts_server_generator },
                },
            }),
        });
        case_obj.expect_errors = .{ .contains = case.expected };
        test_step.dependOn(&case_obj.step);
    }

    // The stack tests: what the framework generates for aida, run in the
    // test stack (docker-compose.yml alone: the default project, 8080).
    const generated = instance.addGenerated(root, b, "../", instance.addGenerate(root, "generate", aida_mod, fw, target, optimize));
    const test_stack = instance.Compose.testStack(generated);
    const apply_schema = test_stack.applySchema(root);

    // `test-backend`: the generated DML module and its generated
    // tests, written into backend/src/, run with `node --test`. Node 22.18+
    // runs .ts directly and the generated tests only use node:test /
    // node:assert, so there is no npm step.
    const run_ts_backend_node_tests = b.addSystemCommand(&.{ "node", "--test", "src/dml.test.ts" });
    run_ts_backend_node_tests.setCwd(root.path("backend"));
    run_ts_backend_node_tests.step.dependOn(generated.write_ts_backend);
    const test_backend_step = b.step("test-backend", "Generate the TypeScript DML module + tests into backend/, then run the pure tests with node");
    test_backend_step.dependOn(&run_ts_backend_node_tests.step);

    // The backend image, with dml.ts and server.ts: test-api and
    // test-backend-db.
    const build_backend_image = test_stack.run(root, &.{ "build", "backend" });
    build_backend_image.step.dependOn(generated.write_ts_backend);
    build_backend_image.step.dependOn(generated.write_ts_server);

    // `test-api`: the generated HTTP server as the backend's
    // long-running process (up, waiting for its healthcheck), the schema
    // applied, then test/http_docker_test.zig requests the API from the host.
    const backend_up = test_stack.run(root, &.{ "up", "-d", "--wait", "backend" });
    backend_up.step.dependOn(&build_backend_image.step);
    backend_up.step.dependOn(apply_schema);
    const run_http_docker_tests = addStackTestRun(b, root, "http_docker_test.zig", target, optimize);
    run_http_docker_tests.step.dependOn(&backend_up.step);
    const test_api_step = b.step("test-api", "Generate the HTTP server, run it in the backend container and request it from the host");
    test_api_step.dependOn(&run_http_docker_tests.step);

    // `test-backend-db`: the generated DML against the database
    // without the HTTP layer, with the values server.ts hands it: the same
    // image as test-api, the schema applied, then test/backend_db_test.zig
    // runs the builders inside the backend container.
    const run_backend_db_tests = addStackTestRun(b, root, "backend_db_test.zig", target, optimize);
    run_backend_db_tests.step.dependOn(&build_backend_image.step);
    run_backend_db_tests.step.dependOn(apply_schema);
    const test_backend_db_step = b.step("test-backend-db", "Run the generated DML inside the backend container against Postgres, with the values of test-api, without HTTP");
    test_backend_db_step.dependOn(&run_backend_db_tests.step);

    // `test-e2e`: the generated frontend in a headless browser.
    // Build the images, bring the frontend up (and the backend with it,
    // waiting for both healthchecks), the schema applied, then
    // test/frontend_e2e_test.zig seeds rows and runs the Playwright suite in
    // the e2e service.
    const build_frontend_images = test_stack.run(root, &.{ "--profile", "e2e", "build", "backend", "frontend", "e2e" });
    build_frontend_images.step.dependOn(generated.write_ts_backend);
    build_frontend_images.step.dependOn(generated.write_ts_server);
    build_frontend_images.step.dependOn(generated.write_frontend);
    const frontend_up = test_stack.run(root, &.{ "up", "-d", "--wait", "frontend" });
    frontend_up.step.dependOn(&build_frontend_images.step);
    frontend_up.step.dependOn(apply_schema);
    const run_frontend_e2e_tests = addStackTestRun(b, root, "frontend_e2e_test.zig", target, optimize);
    run_frontend_e2e_tests.step.dependOn(&frontend_up.step);
    const test_e2e_step = b.step("test-e2e", "Generate the frontend, serve it in its container and test it in a headless browser (Playwright, in a container)");
    test_e2e_step.dependOn(&run_frontend_e2e_tests.step);

    // `test-example`: what `zig build up -Dsystem=examples/aida.zig
    // -Dseed=examples/aida_seed.sql` leaves running (the instance stack,
    // project zigma-aida, 8081), checked by test/example_stack_test.zig. The
    // stack keeps running until `zig build down -Dsystem=examples/aida.zig`.
    const run_example_stack_tests = addStackTestRun(b, root, "example_stack_test.zig", target, optimize);
    run_example_stack_tests.step.dependOn(instance.Compose.instance(generated).upWithFreshDatabase(root, root.path("examples/aida_seed.sql")));
    const test_example_step = b.step("test-example", "Bring the aida instance up (frontend on 8081) with its seed rows, then check it");
    test_example_step.dependOn(&run_example_stack_tests.step);

    // `test-rules-wasm`: compile the rules of the test system to one
    // wasm32 module (src/rules_wasm.zig with test/test_system.zig as its
    // "system") and run test/rules_wasm_node_test.zig, a Zig test that loads
    // it with Node's built-in WebAssembly and calls the rules under the
    // contract. Not on `test_step` (needs Node). The modules are created again
    // for wasm32: every module of a compilation shares its target.
    const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const zigma_wasm_mod = b.createModule(.{
        .root_source_file = root.path("src/zigma.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
    });
    const test_system_wasm_mod = b.createModule(.{
        .root_source_file = b.path("test_system.zig"),
        .target = wasm_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "zigma", .module = zigma_wasm_mod },
        },
    });
    const test_system_rules_wasm = b.addExecutable(.{
        .name = "test_system_rules",
        .root_module = b.createModule(.{
            .root_source_file = root.path("src/rules_wasm.zig"),
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
    const run_rules_wasm_node_tests = addTestRun(b, "rules_wasm_node_test.zig", &.{
        .{ .name = "build_options", .module = rules_wasm_options.createModule() },
    }, target, optimize);

    // Then the generated rules.ts of the test system, next to its compiled
    // rules as rules.wasm (rules.ts loads ./rules.wasm), in a generated
    // directory: test/rules_ts_node_test.zig imports it from Node.
    const generate_test_system_exe = instance.addGenerate(root, "generate_test_system", test_system_mod, fw, target, optimize);
    const run_generate_rules_ts = b.addRunArtifact(generate_test_system_exe);
    run_generate_rules_ts.addArg("rules-ts");
    const test_system_rules_dir = b.addWriteFiles();
    const test_system_rules_ts_path = test_system_rules_dir.addCopyFile(run_generate_rules_ts.captureStdOut(.{}), "rules.ts");
    _ = test_system_rules_dir.addCopyFile(test_system_rules_wasm.getEmittedBin(), "rules.wasm");

    const rules_ts_options = b.addOptions();
    // the path of rules.ts (an option path must be a file); rules.wasm is next to it
    rules_ts_options.addOptionPath("rules_ts_path", test_system_rules_ts_path);
    const run_rules_ts_node_tests = addTestRun(b, "rules_ts_node_test.zig", &.{
        .{ .name = "build_options", .module = rules_ts_options.createModule() },
    }, target, optimize);

    const test_rules_wasm_step = b.step("test-rules-wasm", "Compile the test system's rules to wasm32, generate its rules.ts, and test both from Node");
    test_rules_wasm_step.dependOn(&run_rules_wasm_node_tests.step);
    test_rules_wasm_step.dependOn(&run_rules_ts_node_tests.step);

    // `test-all`: `test`, then every test that needs Node or
    // Docker, one after another, each in its own nested `zig build` process
    // with this build file. New nodes only: an arrow added to the shared
    // nodes (write_ts_backend, apply_schema, ...) would also be there for
    // every other step. One process at a time, so the stack tests never
    // overlap on the shared containers; the first failure stops the chain.
    // test-example is not in it: it leaves the instance stack running.
    const test_all_step = b.step("test-all", "Run test, then every Node/Docker test, one after another");
    var previous: *std.Build.Step = test_step;
    for ([_][]const u8{ "test-backend", "test-backend-db", "test-api", "test-e2e", "test-rules-wasm" }) |name| {
        const nested = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "--build-file" });
        nested.addFileArg(b.path("build.zig"));
        nested.addArg(name);
        nested.setCwd(root.path("."));
        nested.setName(b.fmt("zig build {s}", .{name}));
        nested.step.dependOn(previous);
        previous = &nested.step;
    }
    test_all_step.dependOn(previous);
}
