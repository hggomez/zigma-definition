//! DDL (CREATE TABLE) generation from zigma EntityInfo. Does not know about
//! any concrete system: the domain-type -> SQL-type mapping is supplied by
//! the caller, the same way a system supplies its own `type_defs` to zigma.

const std = @import("std");
const zigma = @import("zigma");

fn sqlType(comptime sql_types: anytype, comptime type_name: []const u8) []const u8 {
    if (!@hasField(@TypeOf(sql_types), type_name))
        @compileError("type '" ++ type_name ++ "' has no SQL mapping");
    return @field(sql_types, type_name);
}

fn isPkField(comptime pk: anytype, comptime name: []const u8) bool {
    inline for (pk) |pk_name| {
        if (comptime std.mem.eql(u8, pk_name, name)) return true;
    }
    return false;
}

/// Pk columns are always `NOT NULL` regardless of `field.nullable`: standard
/// SQL implies it for the pk, but SQLite is the exception and does not
/// enforce it unless declared explicitly.
fn columnClause(comptime sql_types: anytype, comptime pk: anytype, comptime name: []const u8, comptime field: anytype) []const u8 {
    const base = name ++ " " ++ sqlType(sql_types, field.type);
    return if (field.nullable and !isPkField(pk, name)) base else base ++ " NOT NULL";
}

fn joinNames(comptime names: anytype) []const u8 {
    comptime var result: []const u8 = "";
    inline for (names, 0..) |item_name, i| {
        if (i > 0) result = result ++ ", ";
        result = result ++ item_name;
    }
    return result;
}

fn columnListClause(comptime label: []const u8, comptime names: anytype) []const u8 {
    return label ++ " (" ++ joinNames(names) ++ ")";
}

/// `fk.fields` is always the source->target map here (the entity was
/// completed with `zigma.completeEntity` before reaching this function,
/// which normalizes away the array shorthand).
fn fkClause(comptime fk: anytype) []const u8 {
    const source_names = @typeInfo(@TypeOf(fk.fields)).@"struct".field_names;
    comptime var targets: []const u8 = "";
    inline for (source_names, 0..) |source, i| {
        if (i > 0) targets = targets ++ ", ";
        targets = targets ++ @field(fk.fields, source);
    }
    return "FOREIGN KEY (" ++ joinNames(source_names) ++ ") REFERENCES " ++ fk.entity ++ "(" ++ targets ++ ")";
}

fn appendClause(comptime acc: []const u8, comptime clause: []const u8) []const u8 {
    return if (acc.len == 0) clause else acc ++ ",\n    " ++ clause;
}

/// Generates the `CREATE TABLE` statement for one entity: one line per
/// field (with `NOT NULL` when `nullable: false`), then `PRIMARY KEY`, then
/// one `UNIQUE` per uk, then one `FOREIGN KEY` per fk - in that order, each
/// in declaration order. `sql_types` maps each domain type name used by
/// `entity.fields` to its SQL type (e.g. `.{ .text = "TEXT" }`), the same
/// way a system's `type_defs` maps them to Zig types.
pub fn createTableSql(comptime sql_types: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    const field_names = @typeInfo(@TypeOf(entity.fields)).@"struct".field_names;
    comptime var clauses: []const u8 = "";
    inline for (field_names) |field_name| {
        clauses = appendClause(clauses, columnClause(sql_types, entity.pk, field_name, @field(entity.fields, field_name)));
    }
    clauses = appendClause(clauses, columnListClause("PRIMARY KEY", entity.pk));

    const uk_names = @typeInfo(@TypeOf(entity.uks)).@"struct".field_names;
    inline for (uk_names) |uk_name| {
        clauses = appendClause(clauses, columnListClause("UNIQUE", @field(entity.uks, uk_name)));
    }

    const fk_names = @typeInfo(@TypeOf(entity.fks)).@"struct".field_names;
    inline for (fk_names) |fk_name| {
        clauses = appendClause(clauses, fkClause(@field(entity.fks, fk_name)));
    }

    return "CREATE TABLE " ++ name ++ " (\n    " ++ clauses ++ "\n);";
}

/// Generates one `CREATE TABLE` per entity of `entity_defs` (as produced by
/// `zigma.defineEntity`/`zigma.defineEntities`, not yet completed), in
/// declaration order, separated by a blank line.
pub fn schemaSql(comptime sql_types: anytype, comptime entity_defs: anytype) []const u8 {
    // completeEntity's fk-completion loop costs comptime branches per fk;
    // across a whole system's worth of entities that adds up past the
    // default 1000-branch quota (hit at aida's 11 entities).
    @setEvalBranchQuota(10000);
    const entity_names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;
    comptime var statements: []const u8 = "";
    inline for (entity_names, 0..) |entity_name, i| {
        if (i > 0) statements = statements ++ "\n\n";
        const entity_info = zigma.completeEntity(@field(entity_defs, entity_name));
        statements = statements ++ createTableSql(sql_types, entity_name, entity_info);
    }
    return statements;
}
