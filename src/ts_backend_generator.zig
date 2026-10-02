//! DML entry-point generation as TypeScript source, from zigma EntityInfo.
//! Sibling of `sql_generator.zig` (which emits DDL): same idea, but the output
//! string is TypeScript code instead of a `CREATE TABLE` statement. Each
//! field's TS type is resolved from the system's `type_defs` with
//! `zig_type_map_ts.tsType`; the sample literals for the generated tests are
//! still supplied by the caller, keyed by domain type name.
//!
//! Per entity the generator emits up to five parameterized builders, each
//! returning the `{ text, values }` shape a `pg` query call takes:
//! `insert<E>`, `select<E>ByPk`, `selectAll<E>`, `update<E>` (only when the
//! entity has non-pk columns - otherwise there is nothing to SET), `delete<E>`.

const std = @import("std");
const zigma = @import("zigma");

// ---- type resolution ----

const tsType = @import("zig_type_map_ts").tsType;
const sqlType = @import("zig_type_map_sql").sqlType;

/// The struct behind a column's domain type, or null when it is not
/// struct-backed (then the column is one plain parameter).
fn StructOf(comptime type_defs: anytype, comptime type_name: []const u8) ?type {
    if (!@hasField(@TypeOf(type_defs), type_name)) return null;
    const T = @field(type_defs, type_name).Type;
    return if (@typeInfo(T) == .@"struct") T else null;
}

/// A sample literal for a domain type, for the generated tests to feed the
/// builders (the value only has to type-check, not be meaningful). Derived
/// from the domain's Zig type in `type_defs`, consistent with its `tsType`.
fn tsSample(comptime type_defs: anytype, comptime type_name: []const u8) []const u8 {
    if (!@hasField(@TypeOf(type_defs), type_name))
        @compileError("type '" ++ type_name ++ "' has no TS sample");
    return sampleOfZig(type_defs, @field(type_defs, type_name).Type);
}

fn sampleOfZig(comptime type_defs: anytype, comptime T: type) []const u8 {
    return switch (@typeInfo(T)) {
        .bool => "true",
        .int => if (comptime std.mem.eql(u8, tsType(type_defs, @typeName(T)), "bigint")) "1n" else "1",
        .@"struct" => ObjectSample(type_defs, T).ts,
        else => if (T == []const u8) "\"s1\"" else @compileError("type '" ++ @typeName(T) ++ "' has no TS sample"),
    };
}

/// The object literal sample of a struct, one sample per field. Built in a
/// container-level const so it is always evaluated in comptime scope (same
/// trick as `ObjectType` in zig_type_map_ts.zig).
fn ObjectSample(comptime type_defs: anytype, comptime T: type) type {
    return struct {
        pub const ts = blk: {
            const info = @typeInfo(T).@"struct";
            var out: []const u8 = "{ ";
            for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
                if (i > 0) out = out ++ ", ";
                out = out ++ field_name ++ ": " ++ sampleOfZig(type_defs, field_type);
            }
            break :blk out ++ " }";
        };
    };
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
fn pkTypedParams(comptime type_defs: anytype, comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = "";
    inline for (entity.pk, 0..) |col, i| {
        const sep = if (i > 0) ", " else "";
        out = out ++ sep ++ col ++ ": " ++ tsType(type_defs, @field(entity.fields, col).type);
    }
    return out;
}

/// `nombre: string` for the non-pk columns, in declaration order.
fn nonPkTypedParams(comptime type_defs: anytype, comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = "";
    comptime var i: usize = 0;
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |col| {
        if (comptime isPkColumn(entity, col)) continue;
        const sep = if (i > 0) ", " else "";
        out = out ++ sep ++ col ++ ": " ++ tsType(type_defs, @field(entity.fields, col).type);
        i += 1;
    }
    return out;
}

fn placeholder(comptime n: usize) []const u8 {
    return std.fmt.comptimePrint("${d}", .{n});
}

/// A pk column is never NULL, whatever its `nullable` says.
fn isNullableColumn(comptime entity: anytype, comptime col: []const u8) bool {
    return @field(entity.fields, col).nullable and !isPkColumn(entity, col);
}

/// How many query parameters a column takes: one per leaf field for a
/// struct-backed column, one otherwise.
fn paramCount(comptime type_defs: anytype, comptime entity: anytype, comptime col: []const u8) usize {
    const T = StructOf(type_defs, @field(entity.fields, col).type) orelse return 1;
    return @typeInfo(T).@"struct".field_names.len;
}

fn nonPkParamCount(comptime type_defs: anytype, comptime entity: anytype) usize {
    comptime var n: usize = 0;
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |col| {
        if (comptime !isPkColumn(entity, col)) n += paramCount(type_defs, entity, col);
    }
    return n;
}

/// The SQL value of a column whose parameters start at `$first` (the encode
/// half of the codec): `$n` for a plain column; for a struct-backed one,
/// `ROW($n::T1, $n+1::T2, ...)::<composite>`, wrapped in `CASE WHEN ... IS
/// NULL` when the column is nullable (`ROW(NULL, ...)` is not `NULL`).
fn valueExpr(comptime type_defs: anytype, comptime entity: anytype, comptime col: []const u8, comptime first: usize) []const u8 {
    const field = @field(entity.fields, col);
    const T = StructOf(type_defs, field.type) orelse return placeholder(first);
    const info = @typeInfo(T).@"struct";
    comptime var casts: []const u8 = "";
    inline for (info.field_types, 0..) |field_type, i| {
        if (i > 0) casts = casts ++ ", ";
        casts = casts ++ placeholder(first + i) ++ "::" ++ sqlType(type_defs, @typeName(field_type));
    }
    const row = "ROW(" ++ casts ++ ")::" ++ sqlType(type_defs, field.type);
    if (!isNullableColumn(entity, col)) return row;
    const first_cast = placeholder(first) ++ "::" ++ sqlType(type_defs, @typeName(info.field_types[0]));
    return "CASE WHEN " ++ first_cast ++ " IS NULL THEN NULL ELSE " ++ row ++ " END";
}

/// The JS values feeding `valueExpr`'s parameters: `obj.col`, or one per leaf
/// field of a struct-backed column (`obj.col?.f ?? null` when nullable).
fn valueAccessors(comptime type_defs: anytype, comptime entity: anytype, comptime col: []const u8, comptime obj: []const u8) []const u8 {
    const T = StructOf(type_defs, @field(entity.fields, col).type) orelse return obj ++ "." ++ col;
    const nullable = isNullableColumn(entity, col);
    comptime var out: []const u8 = "";
    inline for (@typeInfo(T).@"struct".field_names, 0..) |field_name, i| {
        if (i > 0) out = out ++ ", ";
        out = out ++ if (nullable)
            obj ++ "." ++ col ++ "?." ++ field_name ++ " ?? null"
        else
            obj ++ "." ++ col ++ "." ++ field_name;
    }
    return out;
}

/// The SELECT list (the decode half of the codec): every column by name, a
/// struct-backed one as `to_jsonb("col") AS "col"`, which pg returns as an
/// object.
fn selectList(comptime type_defs: anytype, comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = "";
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names, 0..) |col, i| {
        if (i > 0) out = out ++ ", ";
        out = out ++ if (StructOf(type_defs, @field(entity.fields, col).type) != null)
            "to_jsonb(\"" ++ col ++ "\") AS \"" ++ col ++ "\""
        else
            "\"" ++ col ++ "\"";
    }
    return out;
}

/// `"a" = $1 AND "b" = $2`, the placeholders starting after `offset` params.
fn pkWhere(comptime type_defs: anytype, comptime entity: anytype, comptime offset: usize) []const u8 {
    comptime var out: []const u8 = "";
    comptime var n: usize = offset + 1;
    inline for (entity.pk, 0..) |col, i| {
        const sep = if (i > 0) " AND " else "";
        out = out ++ sep ++ "\"" ++ col ++ "\" = " ++ valueExpr(type_defs, entity, col, n);
        n += paramCount(type_defs, entity, col);
    }
    return out;
}

/// `"nombre" = $1, "precio" = $2` for the non-pk columns (the UPDATE SET list).
fn nonPkAssignments(comptime type_defs: anytype, comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = "";
    comptime var n: usize = 1;
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |col| {
        if (comptime isPkColumn(entity, col)) continue;
        const sep = if (n > 1) ", " else "";
        out = out ++ sep ++ "\"" ++ col ++ "\" = " ++ valueExpr(type_defs, entity, col, n);
        n += paramCount(type_defs, entity, col);
    }
    return out;
}

/// `pk.a, pk.b` (or any object name) for the pk columns.
fn pkAccessors(comptime type_defs: anytype, comptime entity: anytype, comptime obj: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    inline for (entity.pk, 0..) |col, i| {
        const sep = if (i > 0) ", " else "";
        out = out ++ sep ++ valueAccessors(type_defs, entity, col, obj);
    }
    return out;
}

/// `row.nombre, row.precio` for the non-pk columns.
fn nonPkAccessors(comptime type_defs: anytype, comptime entity: anytype, comptime obj: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    comptime var i: usize = 0;
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |col| {
        if (comptime isPkColumn(entity, col)) continue;
        const sep = if (i > 0) ", " else "";
        out = out ++ sep ++ valueAccessors(type_defs, entity, col, obj);
        i += 1;
    }
    return out;
}

/// `cosa: "s1"` for all fields (the sample INSERT row).
fn fieldsSampleObject(comptime type_defs: anytype, comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = "";
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names, 0..) |col, i| {
        const sep = if (i > 0) ", " else "";
        out = out ++ sep ++ col ++ ": " ++ tsSample(type_defs, @field(entity.fields, col).type);
    }
    return out;
}

/// `a: "s1", b: "s1"` for the pk columns (the sample pk object).
fn pkSampleObject(comptime type_defs: anytype, comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = "";
    inline for (entity.pk, 0..) |col, i| {
        const sep = if (i > 0) ", " else "";
        out = out ++ sep ++ col ++ ": " ++ tsSample(type_defs, @field(entity.fields, col).type);
    }
    return out;
}

/// `nombre: "s1"` for the non-pk columns (the sample UPDATE row).
fn nonPkSampleObject(comptime type_defs: anytype, comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = "";
    comptime var i: usize = 0;
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |col| {
        if (comptime isPkColumn(entity, col)) continue;
        const sep = if (i > 0) ", " else "";
        out = out ++ sep ++ col ++ ": " ++ tsSample(type_defs, @field(entity.fields, col).type);
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

/// Parameterized `INSERT` builder for one entity. `type_defs` is the system's
/// collection of domain types; each field's TS type is resolved from it with
/// `tsType`.
pub fn insertFn(comptime type_defs: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    const field_names = @typeInfo(@TypeOf(entity.fields)).@"struct".field_names;

    comptime var params: []const u8 = "";
    comptime var columns: []const u8 = "";
    comptime var placeholders: []const u8 = "";
    comptime var values: []const u8 = "";
    comptime var n: usize = 1;
    inline for (field_names, 0..) |field_name, i| {
        const sep = if (i > 0) ", " else "";
        params = params ++ sep ++ field_name ++ ": " ++ tsType(type_defs, @field(entity.fields, field_name).type);
        columns = columns ++ sep ++ "\"" ++ field_name ++ "\"";
        placeholders = placeholders ++ sep ++ valueExpr(type_defs, entity, field_name, n);
        values = values ++ sep ++ valueAccessors(type_defs, entity, field_name, "row");
        n += paramCount(type_defs, entity, field_name);
    }

    return queryFn(
        opFnName("insert", name, ""),
        "row: { " ++ params ++ " }",
        "INSERT INTO \"" ++ name ++ "\" (" ++ columns ++ ") VALUES (" ++ placeholders ++ ")",
        values,
    );
}

/// Parameterized `SELECT <columns> ... WHERE <pk>` builder for one entity.
pub fn selectByPkFn(comptime type_defs: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    return queryFn(
        opFnName("select", name, "ByPk"),
        "pk: { " ++ pkTypedParams(type_defs, entity) ++ " }",
        "SELECT " ++ selectList(type_defs, entity) ++ " FROM \"" ++ name ++ "\" WHERE " ++ pkWhere(type_defs, entity, 0),
        pkAccessors(type_defs, entity, "pk"),
    );
}

/// `SELECT <columns> FROM <entity>` builder - no parameters.
pub fn selectAllFn(comptime type_defs: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    return queryFn(
        opFnName("selectAll", name, ""),
        "",
        "SELECT " ++ selectList(type_defs, entity) ++ " FROM \"" ++ name ++ "\"",
        "",
    );
}

/// Parameterized full-row `UPDATE` builder: every non-pk column in `SET`,
/// the pk in `WHERE`. Not meaningful for an all-pk entity (nothing to set) -
/// callers should guard with `hasNonPkColumns`.
pub fn updateFn(comptime type_defs: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    return queryFn(
        opFnName("update", name, ""),
        "pk: { " ++ pkTypedParams(type_defs, entity) ++ " }, row: { " ++ nonPkTypedParams(type_defs, entity) ++ " }",
        "UPDATE \"" ++ name ++ "\" SET " ++ nonPkAssignments(type_defs, entity) ++ " WHERE " ++ pkWhere(type_defs, entity, nonPkParamCount(type_defs, entity)),
        nonPkAccessors(type_defs, entity, "row") ++ ", " ++ pkAccessors(type_defs, entity, "pk"),
    );
}

/// Parameterized `DELETE ... WHERE <pk>` builder for one entity.
pub fn deleteFn(comptime type_defs: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    return queryFn(
        opFnName("delete", name, ""),
        "pk: { " ++ pkTypedParams(type_defs, entity) ++ " }",
        "DELETE FROM \"" ++ name ++ "\" WHERE " ++ pkWhere(type_defs, entity, 0),
        pkAccessors(type_defs, entity, "pk"),
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

pub fn insertFnTest(comptime type_defs: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    return queryObjectTest(opFnName("insert", name, ""), "{ " ++ fieldsSampleObject(type_defs, entity) ++ " }");
}

pub fn selectByPkFnTest(comptime type_defs: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    return queryObjectTest(opFnName("select", name, "ByPk"), "{ " ++ pkSampleObject(type_defs, entity) ++ " }");
}

pub fn selectAllFnTest(comptime name: []const u8) []const u8 {
    return queryObjectTest(opFnName("selectAll", name, ""), "");
}

pub fn updateFnTest(comptime type_defs: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    return queryObjectTest(
        opFnName("update", name, ""),
        "{ " ++ pkSampleObject(type_defs, entity) ++ " }, { " ++ nonPkSampleObject(type_defs, entity) ++ " }",
    );
}

pub fn deleteFnTest(comptime type_defs: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    return queryObjectTest(opFnName("delete", name, ""), "{ " ++ pkSampleObject(type_defs, entity) ++ " }");
}

// ---- whole-system aggregation ----

/// Every builder for one entity, in the order insert, selectByPk, selectAll,
/// update (when applicable), delete; blank-line separated.
fn entityBuilders(comptime type_defs: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = insertFn(type_defs, name, entity);
    out = out ++ "\n\n" ++ selectByPkFn(type_defs, name, entity);
    out = out ++ "\n\n" ++ selectAllFn(type_defs, name, entity);
    if (hasNonPkColumns(entity)) out = out ++ "\n\n" ++ updateFn(type_defs, name, entity);
    out = out ++ "\n\n" ++ deleteFn(type_defs, name, entity);
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
fn entityBuilderTests(comptime type_defs: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    comptime var out: []const u8 = insertFnTest(type_defs, name, entity);
    out = out ++ "\n\n" ++ selectByPkFnTest(type_defs, name, entity);
    out = out ++ "\n\n" ++ selectAllFnTest(name);
    if (hasNonPkColumns(entity)) out = out ++ "\n\n" ++ updateFnTest(type_defs, name, entity);
    out = out ++ "\n\n" ++ deleteFnTest(type_defs, name, entity);
    return out;
}

/// The whole `.ts` module for a system: every builder of every entity of
/// `entity_defs` (as produced by `zigma.defineEntity`/`defineEntities`, not
/// yet completed), in declaration order, blank-line separated. The `schemaSql`
/// of the TypeScript side. No header, for parity with `sql_generator`.
pub fn generateTsBackend(comptime type_defs: anytype, comptime entity_defs: anytype) []const u8 {
    @setEvalBranchQuota(100000);
    const entity_names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;
    comptime var module: []const u8 = "";
    inline for (entity_names, 0..) |entity_name, i| {
        if (i > 0) module = module ++ "\n\n";
        module = module ++ entityBuilders(type_defs, entity_name, zigma.completeEntity(@field(entity_defs, entity_name)));
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
pub fn generateTsBackendTests(comptime type_defs: anytype, comptime entity_defs: anytype) []const u8 {
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
        tests = tests ++ entityBuilderTests(type_defs, entity_name, entity);
    }

    return "import { test } from \"node:test\";\n" ++
        "import assert from \"node:assert/strict\";\n" ++
        "\n" ++
        "import { " ++ imports ++ " } from \"" ++ impl_module_path ++ "\";\n" ++
        "\n" ++
        tests;
}
