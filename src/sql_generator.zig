//! DDL (CREATE DOMAIN, CREATE TABLE) generation from zigma EntityInfo. Does
//! not know about any concrete system: each column's SQL type comes from the
//! Zig type behind its domain in the system's `type_defs`, through
//! `zig_type_map_sql.sqlTypeOf`.

const std = @import("std");
const zigma = @import("zigma");
const zig_type_map_sql = @import("zig_type_map_sql");
const SqlType = zig_type_map_sql.SqlType;
const SqlInteger = zig_type_map_sql.SqlInteger;
const SqlField = zig_type_map_sql.SqlField;
const sqlTypeOf = zig_type_map_sql.sqlTypeOf;

// ---- SQL type of a column, from the Zig type of its domain ----

/// The Zig type behind the domain `type_name` of `type_defs`.
fn zigTypeOf(comptime type_defs: anytype, comptime type_name: []const u8) type {
    if (!@hasField(@TypeOf(type_defs), type_name))
        @compileError("type '" ++ type_name ++ "' is not in type_defs");
    return @field(type_defs, type_name).Type;
}

/// The description of the SQL type of a column whose domain is `type_name`.
fn columnSqlType(comptime type_defs: anytype, comptime type_name: []const u8) SqlType {
    return sqlTypeOf(zigTypeOf(type_defs, type_name));
}

fn pgIntegerText(comptime base: zig_type_map_sql.PgInteger) []const u8 {
    return switch (base) {
        .smallint => "SMALLINT",
        .integer => "INTEGER",
        .bigint => "BIGINT",
    };
}

/// The type written in a column (or composite attribute) definition: the
/// domain of a narrow integer (`zig_u8`), otherwise the Postgres type.
fn sqlText(comptime t: SqlType) []const u8 {
    return switch (t) {
        .boolean => "BOOLEAN",
        .text => "TEXT",
        .integer => |int| int.domain orelse pgIntegerText(int.base),
        .composite => @compileError("a composite is written by the name of its domain (columnText)"),
    };
}

/// The type of a column whose domain is `type_name`: a struct domain is the
/// composite named after the domain, anything else `sqlText`.
fn columnText(comptime type_defs: anytype, comptime type_name: []const u8) []const u8 {
    return switch (columnSqlType(type_defs, type_name)) {
        .composite => type_name,
        else => |t| sqlText(t),
    };
}

/// The `CREATE TYPE` of a struct domain: a composite named after the domain,
/// one attribute per field.
fn createTypeSql(comptime name: []const u8, comptime fields: []const SqlField) []const u8 {
    comptime var attributes: []const u8 = "";
    inline for (fields, 0..) |field, i| {
        if (i > 0) attributes = attributes ++ ", ";
        attributes = attributes ++ field.name ++ " " ++ sqlText(field.type);
    }
    return "CREATE TYPE " ++ name ++ " AS (" ++ attributes ++ ");";
}

/// The CHECK that a struct column holds the whole struct or nothing: a
/// composite's attributes cannot be NOT NULL, so once the value is not NULL
/// every field is required.
fn completeClause(comptime entity_name: []const u8, comptime column: []const u8, comptime fields: []const SqlField) []const u8 {
    comptime var required: []const u8 = "";
    inline for (fields, 0..) |field, i| {
        if (i > 0) required = required ++ " AND ";
        required = required ++ "(" ++ column ++ ")." ++ field.name ++ " IS NOT NULL";
    }
    return "CONSTRAINT " ++ entity_name ++ "_" ++ column ++ "_complete CHECK (" ++
        column ++ " IS NULL OR (" ++ required ++ "))";
}

/// The `CREATE DOMAIN` that restricts a narrow integer to its Zig interval.
fn createDomainSql(comptime int: SqlInteger) []const u8 {
    return std.fmt.comptimePrint("CREATE DOMAIN {s} AS {s} CHECK (VALUE BETWEEN {d} AND {d});", .{
        int.domain.?, pgIntegerText(int.base), int.min, int.max,
    });
}

fn containsName(comptime names: []const []const u8, comptime name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
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
fn columnClause(comptime type_defs: anytype, comptime pk: anytype, comptime name: []const u8, comptime field: anytype) []const u8 {
    const base = name ++ " " ++ columnText(type_defs, field.type);
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
/// one `UNIQUE` per uk, then one `FOREIGN KEY` per fk, then one
/// `<entity>_<column>_complete` CHECK per struct column - in that order, each
/// in declaration order. `type_defs` is the system's (the one its records
/// are defined with): each column's SQL type comes from the Zig type of its
/// domain. A narrow integer column is typed with its domain (`zig_u8`), a
/// struct column with the composite named after its domain; their
/// `CREATE DOMAIN` / `CREATE TYPE` are emitted by `schemaSql`.
pub fn createTableSql(comptime type_defs: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    const field_names = @typeInfo(@TypeOf(entity.fields)).@"struct".field_names;
    comptime var clauses: []const u8 = "";
    inline for (field_names) |field_name| {
        clauses = appendClause(clauses, columnClause(type_defs, entity.pk, field_name, @field(entity.fields, field_name)));
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

    inline for (field_names) |field_name| {
        switch (columnSqlType(type_defs, @field(entity.fields, field_name).type)) {
            .composite => |fields| clauses = appendClause(clauses, completeClause(name, field_name, fields)),
            else => {},
        }
    }

    return "CREATE TABLE " ++ name ++ " (\n    " ++ clauses ++ "\n);";
}

/// Generates the whole schema of `entity_defs` (as produced by
/// `zigma.defineEntity`/`zigma.defineEntities`, not yet completed): first one
/// `CREATE DOMAIN` per narrow integer type its columns (or the fields of
/// their composites) use; then one `CREATE TYPE` per struct domain its
/// columns use - each once, in order of first appearance; then one
/// `CREATE TABLE` per entity, in declaration order. Statements are separated
/// by a blank line.
pub fn schemaSql(comptime type_defs: anytype, comptime entity_defs: anytype) []const u8 {
    // completeEntity's fk-completion loop costs comptime branches per fk;
    // across a whole system's worth of entities that adds up past the
    // default 1000-branch quota (hit at aida's 11 entities).
    @setEvalBranchQuota(10000);
    const entity_names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;
    comptime var domains: []const u8 = "";
    comptime var domain_names: []const []const u8 = &.{};
    comptime var types: []const u8 = "";
    comptime var type_names: []const []const u8 = &.{};
    comptime var tables: []const u8 = "";
    inline for (entity_names, 0..) |entity_name, i| {
        const entity_info = zigma.completeEntity(@field(entity_defs, entity_name));
        inline for (@typeInfo(@TypeOf(entity_info.fields)).@"struct".field_names) |field_name| {
            const type_name = @field(entity_info.fields, field_name).type;
            const t = columnSqlType(type_defs, type_name);
            // the domains a column uses: its own, or those of its composite's fields
            const used: []const SqlType = switch (t) {
                .composite => |fields| blk: {
                    var field_types: []const SqlType = &.{};
                    for (fields) |field| field_types = field_types ++ .{field.type};
                    break :blk field_types;
                },
                else => &.{t},
            };
            inline for (used) |u| {
                if (u != .integer) continue;
                const domain = u.integer.domain orelse continue;
                if (containsName(domain_names, domain)) continue;
                domain_names = domain_names ++ .{domain};
                domains = domains ++ createDomainSql(u.integer) ++ "\n\n";
            }
            if (t == .composite and !containsName(type_names, type_name)) {
                type_names = type_names ++ .{type_name};
                types = types ++ createTypeSql(type_name, t.composite) ++ "\n\n";
            }
        }
        if (i > 0) tables = tables ++ "\n\n";
        tables = tables ++ createTableSql(type_defs, entity_name, entity_info);
    }
    return domains ++ types ++ tables;
}
