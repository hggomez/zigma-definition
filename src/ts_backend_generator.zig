//! DML entry-point generation as TypeScript source, from zigma EntityInfo.
//! Sibling of `sql_generator.zig` (which emits DDL): same idea, but the output
//! string is TypeScript code instead of a `CREATE TABLE` statement. The
//! domain-type -> TS-type mapping is supplied by the caller, the same way
//! `sql_generator` takes `sql_types`.

const std = @import("std");
const zigma = @import("zigma");

fn tsType(comptime ts_types: anytype, comptime type_name: []const u8) []const u8 {
    if (!@hasField(@TypeOf(ts_types), type_name))
        @compileError("type '" ++ type_name ++ "' has no TS mapping");
    return @field(ts_types, type_name);
}

/// A sample literal for a domain type, for the generated tests to feed the
/// builders (the value only has to type-check, not be meaningful).
/// `ts_samples` is supplied by the caller keyed by domain type name, the same
/// way `ts_types` / `sql_types` are.
fn tsSample(comptime ts_samples: anytype, comptime type_name: []const u8) []const u8 {
    if (!@hasField(@TypeOf(ts_samples), type_name))
        @compileError("type '" ++ type_name ++ "' has no TS sample");
    return @field(ts_samples, type_name);
}

/// Entity name -> the PascalCase stem of the generated function name
/// (`cosa` -> `insertCosa`). Only the first letter is upper-cased: none of
/// the systems in play have underscored entity names, and a container-level
/// const of a generated struct is the way to get a comptime-known string
/// (same trick as zigma's `LabelHolder`).
fn PascalHolder(comptime name: []const u8) type {
    return struct {
        const value: [name.len]u8 = blk: {
            var out: [name.len]u8 = undefined;
            for (name, 0..) |c, i| out[i] = if (i == 0) std.ascii.toUpper(c) else c;
            break :blk out;
        };
    };
}

/// The name of the generated insert builder for an entity (`cosa` ->
/// `insertCosa`). Shared by the builder and its generated test.
fn insertFnName(comptime name: []const u8) []const u8 {
    return "insert" ++ &PascalHolder(name).value;
}

/// Generates the TypeScript function that builds a parameterized `INSERT`
/// for one entity. `ts_types` maps each domain type name used by
/// `entity.fields` to its TS type (e.g. `.{ .text = "string" }`), the same
/// way a system's `type_defs` maps them to Zig types. Values go out as `$n`
/// placeholders; the returned `{ text, values }` is the shape a `pg` query
/// call takes.
pub fn insertFn(comptime ts_types: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    const field_names = @typeInfo(@TypeOf(entity.fields)).@"struct".field_names;

    comptime var params: []const u8 = "";
    comptime var columns: []const u8 = "";
    comptime var placeholders: []const u8 = "";
    comptime var values: []const u8 = "";
    inline for (field_names, 0..) |field_name, i| {
        const sep = if (i > 0) ", " else "";
        params = params ++ sep ++ field_name ++ ": " ++ tsType(ts_types, @field(entity.fields, field_name).type);
        columns = columns ++ sep ++ "\"" ++ field_name ++ "\"";
        placeholders = placeholders ++ sep ++ std.fmt.comptimePrint("${d}", .{i + 1});
        values = values ++ sep ++ "row." ++ field_name;
    }

    const fn_name = insertFnName(name);
    return "export function " ++ fn_name ++ "(row: { " ++ params ++ " }): { text: string; values: unknown[] } {\n" ++
        "  return {\n" ++
        "    text: 'INSERT INTO \"" ++ name ++ "\" (" ++ columns ++ ") VALUES (" ++ placeholders ++ ")',\n" ++
        "    values: [" ++ values ++ "],\n" ++
        "  };\n" ++
        "}";
}

/// Generates the TypeScript test for one entity's insert builder: builds a
/// sample row, calls the builder, asserts it does not throw and returns a
/// `{ text, values }` query object. Running this in Node is what proves the
/// emitted builder parses, type-checks and executes - the layer a Zig
/// string-assert can't reach. Emits just the `test(...)` block; the imports
/// belong to the whole test module (like `insertFn` emits no imports).
pub fn insertFnTest(comptime ts_samples: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    const field_names = @typeInfo(@TypeOf(entity.fields)).@"struct".field_names;

    comptime var sample_row: []const u8 = "";
    inline for (field_names, 0..) |field_name, i| {
        const sep = if (i > 0) ", " else "";
        sample_row = sample_row ++ sep ++ field_name ++ ": " ++ tsSample(ts_samples, @field(entity.fields, field_name).type);
    }

    const fn_name = insertFnName(name);
    return "test(\"" ++ fn_name ++ ": returns a { text, values } query object\", () => {\n" ++
        "  const q = " ++ fn_name ++ "({ " ++ sample_row ++ " });\n" ++
        "  assert.equal(typeof q.text, \"string\");\n" ++
        "  assert.ok(Array.isArray(q.values));\n" ++
        "});";
}

/// Generates the whole `.ts` module for a system: one insert builder per
/// entity of `entity_defs` (as produced by `zigma.defineEntity`/
/// `defineEntities`, not yet completed), in declaration order, separated by a
/// blank line. The `schemaSql` of the TypeScript side. No header, for parity
/// with `sql_generator.schemaSql`.
pub fn generateTsBackend(comptime ts_types: anytype, comptime entity_defs: anytype) []const u8 {
    @setEvalBranchQuota(10000);
    const entity_names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;
    comptime var module: []const u8 = "";
    inline for (entity_names, 0..) |entity_name, i| {
        if (i > 0) module = module ++ "\n\n";
        module = module ++ insertFn(ts_types, entity_name, zigma.completeEntity(@field(entity_defs, entity_name)));
    }
    return module;
}

/// The path the generated test module imports the builders from. The build
/// step that writes both files owns this name; the generator hard-codes the
/// convention.
const impl_module_path = "./dml.ts";

/// Generates the whole `.ts` test module for a system: the fixed `node:test`
/// / `node:assert` imports, a named import of every entity's builder from the
/// generated impl module, then one `insertFnTest` per entity in declaration
/// order, blank-line separated. The test counterpart of `generateTsBackend`.
pub fn generateTsBackendTests(comptime ts_samples: anytype, comptime entity_defs: anytype) []const u8 {
    @setEvalBranchQuota(10000);
    const entity_names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;

    comptime var imports: []const u8 = "";
    comptime var tests: []const u8 = "";
    inline for (entity_names, 0..) |entity_name, i| {
        if (i > 0) {
            imports = imports ++ ", ";
            tests = tests ++ "\n\n";
        }
        imports = imports ++ insertFnName(entity_name);
        tests = tests ++ insertFnTest(ts_samples, entity_name, zigma.completeEntity(@field(entity_defs, entity_name)));
    }

    return "import { test } from \"node:test\";\n" ++
        "import assert from \"node:assert/strict\";\n" ++
        "\n" ++
        "import { " ++ imports ++ " } from \"" ++ impl_module_path ++ "\";\n" ++
        "\n" ++
        tests;
}
