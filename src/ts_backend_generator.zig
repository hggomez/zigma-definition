//! DML entry-point generation as TypeScript source, from zigma EntityInfo.
//! Sibling of `sql_generator.zig` (which emits DDL): same idea, but the output
//! string is TypeScript code instead of a `CREATE TABLE` statement. The
//! domain-type -> TS-type and domain-type -> sample-literal mappings are
//! supplied by the caller, the same way `sql_generator` takes `sql_types`.
//!
//! Per entity the generator emits up to five parameterized builders, each
//! returning the `{ text, values }` shape a `pg` query call takes:
//! `insert<E>`, `select<E>ByPk`, `selectAll<E>`, `update<E>` (only when the
//! entity has non-pk columns - otherwise there is nothing to SET), `delete<E>`.

const std = @import("std");
const zigma = @import("zigma");

// ---- domain-type maps, supplied by the system (like sql_types) ----

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

// ---- names ----

/// Entity name -> its PascalCase stem. Only the first letter is upper-cased:
/// none of the systems in play have underscored entity names, and a
/// container-level const of a generated struct is the way to get a
/// comptime-known string (same trick as zigma's `LabelHolder`).
fn PascalHolder(comptime name: []const u8) type {
    return struct {
        const value: [name.len]u8 = blk: {
            var out: [name.len]u8 = undefined;
            for (name, 0..) |c, i| out[i] = if (i == 0) std.ascii.toUpper(c) else c;
            break :blk out;
        };
    };
}

/// `opFnName("select", "cosa", "ByPk")` -> `"selectCosaByPk"`. Shared by each
/// builder and its generated test so the two can't disagree on the name.
fn opFnName(comptime prefix: []const u8, comptime name: []const u8, comptime suffix: []const u8) []const u8 {
    const pascal: []const u8 = &PascalHolder(name).value;
    return prefix ++ pascal ++ suffix;
}

// ---- column helpers ----

fn isPkColumn(comptime entity: anytype, comptime col: []const u8) bool {
    inline for (entity.pk) |pk_col| {
        if (comptime std.mem.eql(u8, pk_col, col)) return true;
    }
    return false;
}

fn nonPkCount(comptime entity: anytype) usize {
    comptime var n: usize = 0;
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |col| {
        if (comptime !isPkColumn(entity, col)) n += 1;
    }
    return n;
}

fn hasNonPkColumns(comptime entity: anytype) bool {
    return nonPkCount(entity) > 0;
}

/// `a: string, b: string` for the pk columns, in pk order.
fn pkTypedParams(comptime ts_types: anytype, comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = "";
    inline for (entity.pk, 0..) |col, i| {
        const sep = if (i > 0) ", " else "";
        out = out ++ sep ++ col ++ ": " ++ tsType(ts_types, @field(entity.fields, col).type);
    }
    return out;
}

/// `nombre: string` for the non-pk columns, in declaration order.
fn nonPkTypedParams(comptime ts_types: anytype, comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = "";
    comptime var i: usize = 0;
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |col| {
        if (comptime isPkColumn(entity, col)) continue;
        const sep = if (i > 0) ", " else "";
        out = out ++ sep ++ col ++ ": " ++ tsType(ts_types, @field(entity.fields, col).type);
        i += 1;
    }
    return out;
}

/// `"a" = $1 AND "b" = $2`, the placeholders starting after `offset` params.
fn pkWhere(comptime entity: anytype, comptime offset: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (entity.pk, 0..) |col, i| {
        const sep = if (i > 0) " AND " else "";
        out = out ++ sep ++ "\"" ++ col ++ "\" = " ++ std.fmt.comptimePrint("${d}", .{offset + i + 1});
    }
    return out;
}

/// `"nombre" = $1, "precio" = $2` for the non-pk columns (the UPDATE SET list).
fn nonPkAssignments(comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = "";
    comptime var i: usize = 0;
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |col| {
        if (comptime isPkColumn(entity, col)) continue;
        const sep = if (i > 0) ", " else "";
        out = out ++ sep ++ "\"" ++ col ++ "\" = " ++ std.fmt.comptimePrint("${d}", .{i + 1});
        i += 1;
    }
    return out;
}

/// `pk.a, pk.b` (or any object name) for the pk columns.
fn pkAccessors(comptime entity: anytype, comptime obj: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    inline for (entity.pk, 0..) |col, i| {
        const sep = if (i > 0) ", " else "";
        out = out ++ sep ++ obj ++ "." ++ col;
    }
    return out;
}

/// `row.nombre, row.precio` for the non-pk columns.
fn nonPkAccessors(comptime entity: anytype, comptime obj: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    comptime var i: usize = 0;
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |col| {
        if (comptime isPkColumn(entity, col)) continue;
        const sep = if (i > 0) ", " else "";
        out = out ++ sep ++ obj ++ "." ++ col;
        i += 1;
    }
    return out;
}

/// `cosa: "s1"` for all fields (the sample INSERT row).
fn fieldsSampleObject(comptime ts_samples: anytype, comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = "";
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names, 0..) |col, i| {
        const sep = if (i > 0) ", " else "";
        out = out ++ sep ++ col ++ ": " ++ tsSample(ts_samples, @field(entity.fields, col).type);
    }
    return out;
}

/// `a: "s1", b: "s1"` for the pk columns (the sample pk object).
fn pkSampleObject(comptime ts_samples: anytype, comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = "";
    inline for (entity.pk, 0..) |col, i| {
        const sep = if (i > 0) ", " else "";
        out = out ++ sep ++ col ++ ": " ++ tsSample(ts_samples, @field(entity.fields, col).type);
    }
    return out;
}

/// `nombre: "s1"` for the non-pk columns (the sample UPDATE row).
fn nonPkSampleObject(comptime ts_samples: anytype, comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = "";
    comptime var i: usize = 0;
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |col| {
        if (comptime isPkColumn(entity, col)) continue;
        const sep = if (i > 0) ", " else "";
        out = out ++ sep ++ col ++ ": " ++ tsSample(ts_samples, @field(entity.fields, col).type);
        i += 1;
    }
    return out;
}

// ---- one builder per DML operation ----

fn queryFn(comptime fn_name: []const u8, comptime params: []const u8, comptime text: []const u8, comptime values: []const u8) []const u8 {
    return "export function " ++ fn_name ++ "(" ++ params ++ "): { text: string; values: unknown[] } {\n" ++
        "  return {\n" ++
        "    text: '" ++ text ++ "',\n" ++
        "    values: [" ++ values ++ "],\n" ++
        "  };\n" ++
        "}";
}

/// Parameterized `INSERT` builder for one entity. `ts_types` maps each domain
/// type name to its TS type (e.g. `.{ .text = "string" }`), like a system's
/// `type_defs` maps them to Zig types.
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

    return queryFn(
        opFnName("insert", name, ""),
        "row: { " ++ params ++ " }",
        "INSERT INTO \"" ++ name ++ "\" (" ++ columns ++ ") VALUES (" ++ placeholders ++ ")",
        values,
    );
}

/// Parameterized `SELECT * ... WHERE <pk>` builder for one entity.
pub fn selectByPkFn(comptime ts_types: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    return queryFn(
        opFnName("select", name, "ByPk"),
        "pk: { " ++ pkTypedParams(ts_types, entity) ++ " }",
        "SELECT * FROM \"" ++ name ++ "\" WHERE " ++ pkWhere(entity, 0),
        pkAccessors(entity, "pk"),
    );
}

/// `SELECT * FROM <entity>` builder - no parameters.
pub fn selectAllFn(comptime name: []const u8) []const u8 {
    return queryFn(
        opFnName("selectAll", name, ""),
        "",
        "SELECT * FROM \"" ++ name ++ "\"",
        "",
    );
}

/// Parameterized full-row `UPDATE` builder: every non-pk column in `SET`,
/// the pk in `WHERE`. Not meaningful for an all-pk entity (nothing to set) -
/// callers should guard with `hasNonPkColumns`.
pub fn updateFn(comptime ts_types: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    return queryFn(
        opFnName("update", name, ""),
        "pk: { " ++ pkTypedParams(ts_types, entity) ++ " }, row: { " ++ nonPkTypedParams(ts_types, entity) ++ " }",
        "UPDATE \"" ++ name ++ "\" SET " ++ nonPkAssignments(entity) ++ " WHERE " ++ pkWhere(entity, nonPkCount(entity)),
        nonPkAccessors(entity, "row") ++ ", " ++ pkAccessors(entity, "pk"),
    );
}

/// Parameterized `DELETE ... WHERE <pk>` builder for one entity.
pub fn deleteFn(comptime ts_types: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    return queryFn(
        opFnName("delete", name, ""),
        "pk: { " ++ pkTypedParams(ts_types, entity) ++ " }",
        "DELETE FROM \"" ++ name ++ "\" WHERE " ++ pkWhere(entity, 0),
        pkAccessors(entity, "pk"),
    );
}

// ---- one generated test per builder ----

/// The #1 test: build a typed sample argument set, call the builder, assert
/// it does not throw and returns a `{ text, values }` query object. Running
/// this in Node is what proves the emitted builder parses, type-checks and
/// executes - the layer a Zig string-assert can't reach. Emits just the
/// `test(...)` block; the imports belong to the whole test module.
fn queryObjectTest(comptime fn_name: []const u8, comptime args: []const u8) []const u8 {
    return "test(\"" ++ fn_name ++ ": returns a { text, values } query object\", () => {\n" ++
        "  const q = " ++ fn_name ++ "(" ++ args ++ ");\n" ++
        "  assert.equal(typeof q.text, \"string\");\n" ++
        "  assert.ok(Array.isArray(q.values));\n" ++
        "});";
}

pub fn insertFnTest(comptime ts_samples: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    return queryObjectTest(opFnName("insert", name, ""), "{ " ++ fieldsSampleObject(ts_samples, entity) ++ " }");
}

pub fn selectByPkFnTest(comptime ts_samples: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    return queryObjectTest(opFnName("select", name, "ByPk"), "{ " ++ pkSampleObject(ts_samples, entity) ++ " }");
}

pub fn selectAllFnTest(comptime name: []const u8) []const u8 {
    return queryObjectTest(opFnName("selectAll", name, ""), "");
}

pub fn updateFnTest(comptime ts_samples: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    return queryObjectTest(
        opFnName("update", name, ""),
        "{ " ++ pkSampleObject(ts_samples, entity) ++ " }, { " ++ nonPkSampleObject(ts_samples, entity) ++ " }",
    );
}

pub fn deleteFnTest(comptime ts_samples: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    return queryObjectTest(opFnName("delete", name, ""), "{ " ++ pkSampleObject(ts_samples, entity) ++ " }");
}

// ---- whole-system aggregation ----

/// Every builder for one entity, in the order insert, selectByPk, selectAll,
/// update (when applicable), delete; blank-line separated.
fn entityBuilders(comptime ts_types: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = insertFn(ts_types, name, entity);
    out = out ++ "\n\n" ++ selectByPkFn(ts_types, name, entity);
    out = out ++ "\n\n" ++ selectAllFn(name);
    if (hasNonPkColumns(entity)) out = out ++ "\n\n" ++ updateFn(ts_types, name, entity);
    out = out ++ "\n\n" ++ deleteFn(ts_types, name, entity);
    return out;
}

/// The named-import list matching `entityBuilders`, comma separated.
fn entityBuilderNames(comptime name: []const u8, comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = opFnName("insert", name, "");
    out = out ++ ", " ++ opFnName("select", name, "ByPk");
    out = out ++ ", " ++ opFnName("selectAll", name, "");
    if (hasNonPkColumns(entity)) out = out ++ ", " ++ opFnName("update", name, "");
    out = out ++ ", " ++ opFnName("delete", name, "");
    return out;
}

/// The generated test for every builder of one entity, matching
/// `entityBuilders`; blank-line separated.
fn entityBuilderTests(comptime ts_samples: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = insertFnTest(ts_samples, name, entity);
    out = out ++ "\n\n" ++ selectByPkFnTest(ts_samples, name, entity);
    out = out ++ "\n\n" ++ selectAllFnTest(name);
    if (hasNonPkColumns(entity)) out = out ++ "\n\n" ++ updateFnTest(ts_samples, name, entity);
    out = out ++ "\n\n" ++ deleteFnTest(ts_samples, name, entity);
    return out;
}

/// The whole `.ts` module for a system: every builder of every entity of
/// `entity_defs` (as produced by `zigma.defineEntity`/`defineEntities`, not
/// yet completed), in declaration order, blank-line separated. The `schemaSql`
/// of the TypeScript side. No header, for parity with `sql_generator`.
pub fn generateTsBackend(comptime ts_types: anytype, comptime entity_defs: anytype) []const u8 {
    @setEvalBranchQuota(100000);
    const entity_names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;
    comptime var module: []const u8 = "";
    inline for (entity_names, 0..) |entity_name, i| {
        if (i > 0) module = module ++ "\n\n";
        module = module ++ entityBuilders(ts_types, entity_name, zigma.completeEntity(@field(entity_defs, entity_name)));
    }
    return module;
}

/// The path the generated test module imports the builders from. The build
/// step that writes both files owns this name; the generator hard-codes the
/// convention.
const impl_module_path = "./dml.ts";

/// The whole `.ts` test module for a system: the fixed `node:test` /
/// `node:assert` imports, a named import of every builder from the generated
/// impl module, then the generated test for every builder in declaration
/// order, blank-line separated. The test counterpart of `generateTsBackend`.
pub fn generateTsBackendTests(comptime ts_samples: anytype, comptime entity_defs: anytype) []const u8 {
    @setEvalBranchQuota(100000);
    const entity_names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;

    comptime var imports: []const u8 = "";
    comptime var tests: []const u8 = "";
    inline for (entity_names, 0..) |entity_name, i| {
        const entity = zigma.completeEntity(@field(entity_defs, entity_name));
        if (i > 0) {
            imports = imports ++ ", ";
            tests = tests ++ "\n\n";
        }
        imports = imports ++ entityBuilderNames(entity_name, entity);
        tests = tests ++ entityBuilderTests(ts_samples, entity_name, entity);
    }

    return "import { test } from \"node:test\";\n" ++
        "import assert from \"node:assert/strict\";\n" ++
        "\n" ++
        "import { " ++ imports ++ " } from \"" ++ impl_module_path ++ "\";\n" ++
        "\n" ++
        tests;
}
