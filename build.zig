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

    const schema_sql_mod = b.addModule("schema_sql", .{
        .root_source_file = b.path("src/schema_sql.zig"),
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

    const schema_sql_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/schema_sql_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zigma", .module = zigma_mod },
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "schema_sql", .module = schema_sql_mod },
            },
        }),
    });
    const run_schema_sql_tests = b.addRunArtifact(schema_sql_tests);

    const test_step = b.step("test", "Run tests (runtime and expected compile errors)");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_schema_sql_tests.step);

    // `zig build create-database`: prints the aida schema (tools/print_aida_schema.zig)
    // and pipes it into psql, running inside the Postgres container started by
    // `docker compose up -d` (see docker-compose.yml).
    const print_aida_schema = b.addExecutable(.{
        .name = "print_aida_schema",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/print_aida_schema.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "aida", .module = aida_mod },
                .{ .name = "schema_sql", .module = schema_sql_mod },
            },
        }),
    });
    const run_print_aida_schema = b.addRunArtifact(print_aida_schema);
    const aida_schema_sql = run_print_aida_schema.captureStdOut(.{});

    const apply_aida_schema = b.addSystemCommand(&.{
        "docker", "exec", "-i", "zigma_aida_postgres",
        "psql",   "-U",   "aida", "-d", "aida",
    });
    apply_aida_schema.setStdIn(.{ .lazy_path = aida_schema_sql });

    const create_database_step = b.step("create-database", "Generate the aida schema and apply it to the running Postgres container");
    create_database_step.dependOn(&apply_aida_schema.step);

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
                },
            }),
        });
        case_obj.expect_errors = .{ .contains = case.expected };
        test_step.dependOn(&case_obj.step);
    }
}
