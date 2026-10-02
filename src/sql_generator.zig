//! DDL (CREATE TABLE) generation from zigma EntityInfo. Does not know about
//! any concrete system: it receives the system's `type_defs` and resolves each
//! field's SQL type with `zig_type_map_sql.sqlType`.

const std = @import("std");
const zigma = @import("zigma");
const sqlType = @import("zig_type_map_sql").sqlType;
const sqlDomain = @import("zig_type_map_sql").sqlDomain;

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
    const base = name ++ " " ++ sqlType(type_defs, field.type);
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

// ---- constraint names ----
//
// Every key is a named constraint, named from the SSOT. Postgres reports a
// violated constraint by that name, so the backend can map the violation back
// to the entity and key of the definition (`domainErrorFn` of
// ts_backend_generator uses these same functions).

pub fn pkConstraintName(comptime entity_name: []const u8) []const u8 {
    return entity_name ++ "_pk";
}

pub fn ukConstraintName(comptime entity_name: []const u8, comptime uk_name: []const u8) []const u8 {
    return entity_name ++ "_uk_" ++ uk_name;
}

pub fn fkConstraintName(comptime entity_name: []const u8, comptime fk_name: []const u8) []const u8 {
    return entity_name ++ "_fk_" ++ fk_name;
}

fn columnListClause(comptime constraint_name: []const u8, comptime label: []const u8, comptime names: anytype) []const u8 {
    return "CONSTRAINT " ++ constraint_name ++ " " ++ label ++ " (" ++ joinNames(names) ++ ")";
}

/// `fk.fields` is always the source->target map here (the entity was
/// completed with `zigma.completeEntity` before reaching this function,
/// which normalizes away the array shorthand).
fn fkClause(comptime constraint_name: []const u8, comptime fk: anytype) []const u8 {
    const source_names = @typeInfo(@TypeOf(fk.fields)).@"struct".field_names;
    comptime var targets: []const u8 = "";
    inline for (source_names, 0..) |source, i| {
        if (i > 0) targets = targets ++ ", ";
        targets = targets ++ @field(fk.fields, source);
    }
    return "CONSTRAINT " ++ constraint_name ++ " FOREIGN KEY (" ++ joinNames(source_names) ++ ") REFERENCES " ++ fk.entity ++ "(" ++ targets ++ ")";
}

fn appendClause(comptime acc: []const u8, comptime clause: []const u8) []const u8 {
    return if (acc.len == 0) clause else acc ++ ",\n    " ++ clause;
}

/// Generates the `CREATE TABLE` statement for one entity: one line per
/// field (with `NOT NULL` when `nullable: false`), then `PRIMARY KEY`, then
/// one `UNIQUE` per uk, then one `FOREIGN KEY` per fk - in that order, each
/// in declaration order, each key a named constraint (see the constraint
/// names above). `type_defs` is the system's collection of domain
/// types; each field's SQL type is resolved from it with `sqlType`.
pub fn createTableSql(comptime type_defs: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    const field_names = @typeInfo(@TypeOf(entity.fields)).@"struct".field_names;
    comptime var clauses: []const u8 = "";
    inline for (field_names) |field_name| {
        clauses = appendClause(clauses, columnClause(type_defs, entity.pk, field_name, @field(entity.fields, field_name)));
    }
    clauses = appendClause(clauses, columnListClause(pkConstraintName(name), "PRIMARY KEY", entity.pk));

    const uk_names = @typeInfo(@TypeOf(entity.uks)).@"struct".field_names;
    inline for (uk_names) |uk_name| {
        clauses = appendClause(clauses, columnListClause(ukConstraintName(name, uk_name), "UNIQUE", @field(entity.uks, uk_name)));
    }

    const fk_names = @typeInfo(@TypeOf(entity.fks)).@"struct".field_names;
    inline for (fk_names) |fk_name| {
        clauses = appendClause(clauses, fkClause(fkConstraintName(name, fk_name), @field(entity.fks, fk_name)));
    }

    return "CREATE TABLE " ++ name ++ " (\n    " ++ clauses ++ "\n);";
}

/// Generates the `CREATE TYPE` (Postgres composite type) of a struct-backed
/// domain of `type_defs`.
/// Each field's SQL type comes from its Zig type through `sqlType` (only leaf
/// primitives for now: a struct nested in a struct has no mapping yet).
pub fn createTypeSql(comptime type_defs: anytype, comptime name: []const u8) []const u8 {
    if (!isStructDomain(type_defs, name))
        @compileError("type '" ++ name ++ "' is not a struct-backed domain");
    const info = @typeInfo(@field(type_defs, name).Type).@"struct";
    comptime var clauses: []const u8 = "";
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        clauses = appendClause(clauses, field_name ++ " " ++ sqlType(type_defs, @typeName(field_type)));
    }
    return "CREATE TYPE " ++ name ++ " AS (\n    " ++ clauses ++ "\n);";
}

/// Generates the `CREATE DOMAIN` of a Zig integer type narrower than its
/// Postgres integer (`zig_type_map_sql.sqlDomain`): the column type checked
/// to the Zig range.
pub fn createDomainSql(comptime T: type) []const u8 {
    const domain = sqlDomain(T) orelse
        @compileError("type '" ++ @typeName(T) ++ "' needs no SQL domain");
    return std.fmt.comptimePrint("CREATE DOMAIN {s} AS {s} CHECK (VALUE BETWEEN {d} AND {d});", .{
        domain.name, domain.base, domain.min, domain.max,
    });
}

/// The Zig types of `type_defs` that need a SQL domain, each once, in order
/// of first appearance (a struct-backed domain contributes its fields).
fn domainTypes(comptime type_defs: anytype) []const type {
    comptime var found: []const type = &.{};
    inline for (@typeInfo(@TypeOf(type_defs)).@"struct".field_names) |type_name| {
        const T = @field(type_defs, type_name).Type;
        const candidates: []const type = switch (@typeInfo(T)) {
            .@"struct" => |info| info.field_types,
            else => &.{T},
        };
        inline for (candidates) |C| {
            if (sqlDomain(C) == null) continue;
            const seen = inline for (found) |F| {
                if (F == C) break true;
            } else false;
            if (!seen) found = found ++ [_]type{C};
        }
    }
    return found;
}

fn isStructDomain(comptime type_defs: anytype, comptime name: []const u8) bool {
    if (!@hasField(@TypeOf(type_defs), name)) return false;
    return @typeInfo(@field(type_defs, name).Type) == .@"struct";
}

/// Generates one `CREATE DOMAIN` per narrow integer type the system's types
/// use, then one `CREATE TYPE` per struct-backed domain of `type_defs`, then
/// one `CREATE TABLE` per entity of `entity_defs` (as produced by
/// `zigma.defineEntity`/`zigma.defineEntities`, not yet completed), each in
/// declaration order, separated by a blank line. Each group goes before the
/// one that references it.
pub fn schemaSql(comptime type_defs: anytype, comptime entity_defs: anytype) []const u8 {
    // completeEntity's fk-completion loop costs comptime branches per fk;
    // across a whole system's worth of entities that adds up past the
    // default 1000-branch quota (hit at aida's 11 entities).
    @setEvalBranchQuota(10000);
    comptime var statements: []const u8 = "";
    inline for (domainTypes(type_defs)) |T| {
        statements = statements ++ createDomainSql(T) ++ "\n\n";
    }
    inline for (@typeInfo(@TypeOf(type_defs)).@"struct".field_names) |type_name| {
        if (comptime !isStructDomain(type_defs, type_name)) continue;
        statements = statements ++ createTypeSql(type_defs, type_name) ++ "\n\n";
    }
    const entity_names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;
    inline for (entity_names, 0..) |entity_name, i| {
        if (i > 0) statements = statements ++ "\n\n";
        const entity_info = zigma.completeEntity(@field(entity_defs, entity_name));
        statements = statements ++ createTableSql(type_defs, entity_name, entity_info);
    }
    return statements;
}
