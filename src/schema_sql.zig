//! Generates PostgreSQL DDL from an entity Info (see zigma.completeEntity).
//! Two-phase: CREATE TABLE per entity first (columns + PRIMARY KEY only),
//! foreign keys as a separate ALTER TABLE pass — so table creation order and
//! circular/reflexive fks never need special handling.
//!
//! NOTE: like some functions in zigma.zig, this accumulates a compile-time
//! string with `comptime var` / `inline for`. Call it from a container-level
//! (top-level) const, not directly inside a runtime function body — see the
//! CLAUDE.md note on "redundant comptime".

const std = @import("std");
const zigma = @import("zigma");

fn eql(comptime a: []const u8, comptime b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn containsName(comptime names: anytype, comptime name: []const u8) bool {
    inline for (names) |n| {
        if (eql(n, name)) return true;
    }
    return false;
}

fn sqlType(comptime type_sql: anytype, comptime domain_type: []const u8) []const u8 {
    if (!@hasField(@TypeOf(type_sql), domain_type))
        @compileError("no SQL type mapped for domain type '" ++ domain_type ++ "'");
    return @field(type_sql, domain_type);
}

/// One column definition: 'name TYPE[ NOT NULL]'. A pk field is always
/// NOT NULL in the DDL, even when its Info says nullable: true (that default
/// is about the field on its own, not about being part of the pk).
fn columnSql(comptime name: []const u8, comptime field: anytype, comptime pk: anytype, comptime type_sql: anytype) []const u8 {
    const not_null = !field.nullable or containsName(pk, name);
    return name ++ " " ++ sqlType(type_sql, field.type) ++ (if (not_null) " NOT NULL" else "");
}

pub fn createTableStatement(comptime entity_name: []const u8, comptime info: anytype, comptime type_sql: anytype) []const u8 {
    comptime var columns: []const u8 = "";
    inline for (@typeInfo(@TypeOf(info.fields)).@"struct".field_names, 0..) |name, i| {
        columns = columns ++ (if (i == 0) "" else ",\n") ++ "    " ++ columnSql(name, @field(info.fields, name), info.pk, type_sql);
    }
    comptime var pk_list: []const u8 = "";
    inline for (info.pk, 0..) |name, i| {
        pk_list = pk_list ++ (if (i == 0) "" else ", ") ++ name;
    }
    return "CREATE TABLE " ++ entity_name ++ " (\n" ++ columns ++ ",\n    PRIMARY KEY (" ++ pk_list ++ ")\n);";
}

/// One fk, as its own statement: 'ALTER TABLE source ADD FOREIGN KEY (...)
/// REFERENCES target (...)'. Kept apart from CREATE TABLE (see
/// createSchemaStatements) so table creation order and circular/reflexive
/// fks never need special handling.
fn addForeignKeyStatement(comptime entity_name: []const u8, comptime fk: anytype) []const u8 {
    comptime var source_cols: []const u8 = "";
    comptime var target_cols: []const u8 = "";
    inline for (@typeInfo(@TypeOf(fk.fields)).@"struct".field_names, 0..) |source, i| {
        const target: []const u8 = @field(fk.fields, source);
        source_cols = source_cols ++ (if (i == 0) "" else ", ") ++ source;
        target_cols = target_cols ++ (if (i == 0) "" else ", ") ++ target;
    }
    return "ALTER TABLE " ++ entity_name ++ " ADD FOREIGN KEY (" ++ source_cols ++ ") REFERENCES " ++ fk.entity ++ " (" ++ target_cols ++ ");";
}

/// The whole database for a system: every entity's CREATE TABLE, then every
/// fk's ALTER TABLE ADD FOREIGN KEY, in that order.
pub fn createSchemaStatements(comptime entity_defs: anytype, comptime type_sql: anytype) []const u8 {
    // a real system has enough entities/fields/fks that completing every
    // entity here exceeds the default comptime branch quota.
    @setEvalBranchQuota(100_000);
    comptime var tables: []const u8 = "";
    comptime var fks: []const u8 = "";
    inline for (@typeInfo(@TypeOf(entity_defs)).@"struct".field_names, 0..) |entity_name, i| {
        const info = zigma.completeEntity(@field(entity_defs, entity_name));
        tables = tables ++ (if (i == 0) "" else "\n\n") ++ createTableStatement(entity_name, info, type_sql);
        inline for (@typeInfo(@TypeOf(info.fks)).@"struct".field_names) |fk_name| {
            fks = fks ++ (if (fks.len == 0) "" else "\n") ++ addForeignKeyStatement(entity_name, @field(info.fks, fk_name));
        }
    }
    if (fks.len == 0) return tables;
    return tables ++ "\n\n" ++ fks;
}
