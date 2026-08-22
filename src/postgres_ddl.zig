//! Pure comptime PostgreSQL DDL generation for zigma system definitions.
//! This module only renders complete CREATE TABLE statements. It does not
//! connect to a database, inspect an existing schema, or generate migrations.

const std = @import("std");
const zigma = @import("zigma");

const max_identifier_bytes = 63;

/// The PostgreSQL representation of one domain type. Kept separate from
/// `zigma.TypeDef` so the descriptive system remains database-agnostic.
pub const TypeMapping = struct {
    sql_type: []const u8,
};

/// PostgreSQL mappings for zigma's built-in domain types.
pub const common_type_mappings = defineTypeMappings(.{
    .text = TypeMapping{ .sql_type = "TEXT" },
    .integer = TypeMapping{ .sql_type = "BIGINT" },
    .boolean = TypeMapping{ .sql_type = "BOOLEAN" },
});

fn eql(comptime a: []const u8, comptime b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isStringType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child == u8,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

fn checkTypeMapping(comptime mapping: anytype, comptime name: []const u8) void {
    const Mapping = @TypeOf(mapping);
    const info = @typeInfo(Mapping);
    if (info != .@"struct" or info.@"struct".is_tuple)
        @compileError("PostgreSQL type mapping '" ++ name ++ "': must be a struct like .{ .sql_type = \"TEXT\" }");
    if (info.@"struct".field_names.len != 1 or !@hasField(Mapping, "sql_type"))
        @compileError("PostgreSQL type mapping '" ++ name ++ "': must contain only 'sql_type'");
    if (!isStringType(@TypeOf(mapping.sql_type)))
        @compileError("PostgreSQL type mapping '" ++ name ++ "': 'sql_type' must be a non-empty string");
    if (mapping.sql_type.len == 0)
        @compileError("PostgreSQL type mapping '" ++ name ++ "': 'sql_type' must be a non-empty string");
}

fn checkTypeMappings(comptime mappings: anytype) void {
    const info = @typeInfo(@TypeOf(mappings));
    if (info != .@"struct" or info.@"struct".is_tuple)
        @compileError("PostgreSQL type mappings must be a struct of TypeMapping values");
    inline for (info.@"struct".field_names) |name| {
        checkTypeMapping(@field(mappings, name), name);
    }
}

/// Validates PostgreSQL domain-type mappings at their declaration site and
/// returns them unchanged, preserving their exact anonymous struct type.
pub fn defineTypeMappings(comptime mappings: anytype) @TypeOf(mappings) {
    comptime checkTypeMappings(mappings);
    return mappings;
}

fn validateIdentifier(comptime identifier: []const u8) void {
    if (identifier.len == 0)
        @compileError("PostgreSQL identifiers must not be empty");
    if (identifier.len > max_identifier_bytes)
        @compileError("PostgreSQL identifier '" ++ identifier ++ "' exceeds 63 bytes");
}

fn QuotedIdentifier(comptime identifier: []const u8) type {
    const quoted_len = blk: {
        var len: usize = 2;
        for (identifier) |char| len += if (char == '\"') 2 else 1;
        break :blk len;
    };
    return struct {
        const value: [quoted_len]u8 = blk: {
            var result: [quoted_len]u8 = undefined;
            var index: usize = 0;
            result[index] = '\"';
            index += 1;
            for (identifier) |char| {
                result[index] = char;
                index += 1;
                if (char == '\"') {
                    result[index] = '\"';
                    index += 1;
                }
            }
            result[index] = '\"';
            break :blk result;
        };
    };
}

fn quoteIdentifier(comptime identifier: []const u8) []const u8 {
    validateIdentifier(identifier);
    return &QuotedIdentifier(identifier).value;
}

fn containsName(comptime names: anytype, comptime wanted: []const u8) bool {
    var index: usize = 0;
    while (index < names.len) : (index += 1) {
        if (eql(names[index], wanted)) return true;
    }
    return false;
}

fn quoteNameList(comptime names: anytype) []const u8 {
    comptime var result: []const u8 = "";
    comptime var index: usize = 0;
    inline while (index < names.len) : (index += 1) {
        if (index != 0) result = result ++ ", ";
        result = result ++ quoteIdentifier(names[index]);
    }
    return result;
}

fn quoteStructFieldNames(comptime StructType: type) []const u8 {
    comptime var result: []const u8 = "";
    inline for (@typeInfo(StructType).@"struct".field_names, 0..) |name, index| {
        if (index != 0) result = result ++ ", ";
        result = result ++ quoteIdentifier(name);
    }
    return result;
}

fn quoteStructFieldValues(comptime values: anytype) []const u8 {
    comptime var result: []const u8 = "";
    inline for (@typeInfo(@TypeOf(values)).@"struct".field_names, 0..) |name, index| {
        if (index != 0) result = result ++ ", ";
        result = result ++ quoteIdentifier(@field(values, name));
    }
    return result;
}

fn sqlTypeFor(
    comptime table_name: []const u8,
    comptime field_name: []const u8,
    comptime domain_type: []const u8,
    comptime type_mappings: anytype,
) []const u8 {
    if (!@hasField(@TypeOf(type_mappings), domain_type))
        @compileError("entity '" ++ table_name ++ "', field '" ++ field_name ++ "': missing PostgreSQL type mapping for domain type '" ++ domain_type ++ "'");
    return @field(type_mappings, domain_type).sql_type;
}

fn primaryConstraintName(comptime table_name: []const u8) []const u8 {
    return "pk_" ++ table_name;
}

fn uniqueConstraintName(comptime table_name: []const u8, comptime uk_name: []const u8) []const u8 {
    return "uk_" ++ table_name ++ "_" ++ uk_name;
}

fn foreignConstraintName(comptime table_name: []const u8, comptime fk_name: []const u8) []const u8 {
    return "fk_" ++ table_name ++ "_" ++ fk_name;
}

fn CompletedEntityHolder(comptime entity: anytype) type {
    return struct {
        const value = zigma.completeEntity(entity);
    };
}

fn renderTable(
    comptime table_name: []const u8,
    comptime entity: anytype,
    comptime type_mappings: anytype,
) []const u8 {
    validateIdentifier(table_name);
    const info = CompletedEntityHolder(entity).value;
    if (info.pk.len == 0)
        @compileError("entity '" ++ table_name ++ "': PostgreSQL DDL requires a non-empty pk");

    comptime var ddl: []const u8 = "CREATE TABLE IF NOT EXISTS " ++ quoteIdentifier(table_name) ++ " (\n";

    inline for (@typeInfo(@TypeOf(info.fields)).@"struct".field_names) |field_name| {
        validateIdentifier(field_name);
        const field = @field(info.fields, field_name);
        const sql_type = sqlTypeFor(table_name, field_name, field.type, type_mappings);
        const not_null = !field.nullable or containsName(info.pk, field_name);
        ddl = ddl ++ "    " ++ quoteIdentifier(field_name) ++ " " ++ sql_type ++ (if (not_null) " NOT NULL" else "") ++ ",\n";
    }

    ddl = ddl ++ "    CONSTRAINT " ++ quoteIdentifier(primaryConstraintName(table_name)) ++
        " PRIMARY KEY (" ++ quoteNameList(info.pk) ++ ")";

    inline for (@typeInfo(@TypeOf(info.uks)).@"struct".field_names) |uk_name| {
        const constraint_name = uniqueConstraintName(table_name, uk_name);
        ddl = ddl ++ ",\n    CONSTRAINT " ++ quoteIdentifier(constraint_name) ++
            " UNIQUE (" ++ quoteNameList(@field(info.uks, uk_name)) ++ ")";
    }

    inline for (@typeInfo(@TypeOf(info.fks)).@"struct".field_names) |fk_name| {
        const fk = @field(info.fks, fk_name);
        const constraint_name = foreignConstraintName(table_name, fk_name);
        ddl = ddl ++ ",\n    CONSTRAINT " ++ quoteIdentifier(constraint_name) ++
            " FOREIGN KEY (" ++ quoteStructFieldNames(@TypeOf(fk.fields)) ++ ")" ++
            " REFERENCES " ++ quoteIdentifier(fk.entity) ++
            " (" ++ quoteStructFieldValues(fk.fields) ++ ")";
    }

    return ddl ++ "\n);\n";
}

fn RenderedTable(
    comptime table_name: []const u8,
    comptime entity: anytype,
    comptime type_mappings: anytype,
) type {
    return struct {
        const value: []const u8 = renderTable(table_name, entity, type_mappings);
    };
}

fn indexOfName(comptime names: anytype, comptime wanted: []const u8) usize {
    for (names, 0..) |name, index| {
        if (eql(name, wanted)) return index;
    }
    unreachable;
}

fn SchemaOrder(comptime entity_defs: anytype) type {
    const entity_names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;
    return struct {
        const names: [entity_names.len][:0]const u8 = blk: {
            var result: [entity_names.len][:0]const u8 = undefined;
            var emitted: [entity_names.len]bool = @splat(false);
            var result_len: usize = 0;

            while (result_len < entity_names.len) {
                var made_progress = false;
                for (entity_names, 0..) |entity_name, entity_index| {
                    if (emitted[entity_index]) continue;
                    const entity = @field(entity_defs, entity_name);
                    var dependencies_ready = true;
                    for (@typeInfo(@TypeOf(entity.fks)).@"struct".field_names) |fk_name| {
                        const target = @field(entity.fks, fk_name).entity;
                        if (eql(target, entity_name)) continue;
                        if (!emitted[indexOfName(entity_names, target)]) {
                            dependencies_ready = false;
                            break;
                        }
                    }
                    if (dependencies_ready) {
                        result[result_len] = entity_name;
                        result_len += 1;
                        emitted[entity_index] = true;
                        made_progress = true;
                    }
                }
                if (!made_progress) {
                    for (entity_names, 0..) |entity_name, entity_index| {
                        if (!emitted[entity_index])
                            @compileError("PostgreSQL DDL: foreign key cycle involving entity '" ++ entity_name ++ "' cannot be generated with inline constraints");
                    }
                    unreachable;
                }
            }
            break :blk result;
        };
    };
}

/// Generates one complete `CREATE TABLE IF NOT EXISTS` statement. The full
/// entity collection is accepted so system-level foreign keys are validated
/// before selecting the requested table.
pub fn createTableDdl(
    comptime entity_defs: anytype,
    comptime table_name: []const u8,
    comptime type_mappings: anytype,
) []const u8 {
    comptime checkTypeMappings(type_mappings);
    const validated = zigma.defineEntities(entity_defs);
    if (!@hasField(@TypeOf(validated), table_name))
        @compileError("PostgreSQL DDL: unknown entity '" ++ table_name ++ "'");
    return RenderedTable(table_name, @field(validated, table_name), type_mappings).value;
}

/// Generates the complete PostgreSQL schema. Referenced tables come before
/// their dependants, independent entities keep declaration order, and
/// self-referential foreign keys remain inline.
pub fn createSchemaDdl(comptime entity_defs: anytype, comptime type_mappings: anytype) []const u8 {
    comptime checkTypeMappings(type_mappings);
    const validated = zigma.defineEntities(entity_defs);
    comptime var ddl: []const u8 = "";
    inline for (SchemaOrder(validated).names, 0..) |table_name, index| {
        if (index != 0) ddl = ddl ++ "\n";
        ddl = ddl ++ RenderedTable(table_name, @field(validated, table_name), type_mappings).value;
    }
    return ddl;
}
