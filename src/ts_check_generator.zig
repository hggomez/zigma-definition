//! Generation of `check.ts`: for each entity, the restrictions of its fields
//! derived from their Zig types, and the generic `check` that finds every way
//! a TS value breaks them. The TS side runs it on every value that enters it
//! (HTTP -> TS now, HTTP -> frontend later), so a value that the Zig types
//! cannot hold is rejected there, before it goes on (the database enforces
//! the same ranges with domains, see `zig_type_map_sql.sqlDomain`).
//!
//! Per field: its TS type (`tsType`: "string", "number", "bigint",
//! "boolean"; a struct is an "object" with its fields), for an integer the
//! range of its Zig type (`std.math.minInt` / `maxInt`), and `nullable: true`
//! only when the field is nullable and not part of the pk. Sibling of
//! `ts_backend_generator.zig` / `ts_rules_generator.zig`.

const std = @import("std");
const tsType = @import("zig_type_map_ts").tsType;

/// The fixed part of `check.ts`: the `Restriction` type and the generic
/// `check`. `check` returns every problem as `{ field, problem }` (a dotted
/// path for a struct field), in field order, then the keys that are not
/// fields; the empty list when the value follows the restrictions. A missing
/// field is a problem even when it is nullable: null has to be explicit.
pub const check_prelude =
    \\export type Restriction =
    \\  | { type: "string"; nullable?: true }
    \\  | { type: "boolean"; nullable?: true }
    \\  | { type: "number"; min: number; max: number; nullable?: true }
    \\  | { type: "bigint"; min: bigint; max: bigint; nullable?: true }
    \\  | { type: "object"; fields: Record<string, Restriction>; nullable?: true };
    \\
    \\export type Problem = { field: string; problem: string };
    \\
    \\// Every problem of `value` against `restrictions`: one per field, in field
    \\// order, then the keys that are not fields. Empty when the value follows them.
    \\export function check(restrictions: Record<string, Restriction>, value: unknown, path = ""): Problem[] {
    \\  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    \\    return [{ field: path, problem: "expected an object" }];
    \\  }
    \\  const record = value as Record<string, unknown>;
    \\  const at = (name: string) => (path === "" ? name : path + "." + name);
    \\  const problems: Problem[] = [];
    \\  for (const [name, restriction] of Object.entries(restrictions)) {
    \\    if (!Object.hasOwn(record, name)) problems.push({ field: at(name), problem: "missing" });
    \\    else problems.push(...checkValue(restriction, record[name], at(name)));
    \\  }
    \\  for (const name of Object.keys(record)) {
    \\    if (!Object.hasOwn(restrictions, name)) problems.push({ field: at(name), problem: "not a field" });
    \\  }
    \\  return problems;
    \\}
    \\
    \\function checkValue(restriction: Restriction, value: unknown, field: string): Problem[] {
    \\  if (value === null) return restriction.nullable ? [] : [{ field, problem: "must not be null" }];
    \\  switch (restriction.type) {
    \\    case "object":
    \\      if (typeof value !== "object" || Array.isArray(value)) return [{ field, problem: "expected an object" }];
    \\      return check(restriction.fields, value, field);
    \\    case "number":
    \\      if (typeof value !== "number") return [{ field, problem: "expected a number" }];
    \\      if (!Number.isInteger(value)) return [{ field, problem: "must be an integer" }];
    \\      return inRange(restriction, value, field);
    \\    case "bigint":
    \\      if (typeof value !== "bigint") return [{ field, problem: "expected a bigint" }];
    \\      return inRange(restriction, value, field);
    \\    default:
    \\      return typeof value === restriction.type ? [] : [{ field, problem: "expected a " + restriction.type }];
    \\  }
    \\}
    \\
    \\function inRange<T extends number | bigint>(restriction: { min: T; max: T }, value: T, field: string): Problem[] {
    \\  if (value >= restriction.min && value <= restriction.max) return [];
    \\  return [{ field, problem: `out of range ${restriction.min}..${restriction.max}` }];
    \\}
;

/// The inside of the restriction of Zig type `T` (without the braces):
/// `type: "number", min: 0, max: 255`, or for a struct `type: "object",
/// fields: { ... }`.
fn restrictionBody(comptime type_defs: anytype, comptime T: type) []const u8 {
    switch (@typeInfo(T)) {
        .@"struct" => |info| {
            comptime var fields: []const u8 = "";
            inline for (info.field_names, info.field_types, 0..) |field_name, field_type, i| {
                if (i > 0) fields = fields ++ ", ";
                fields = fields ++ field_name ++ ": { " ++ restrictionBody(type_defs, field_type) ++ " }";
            }
            return "type: \"object\", fields: { " ++ fields ++ " }";
        },
        .int => {
            const ts_type = tsType(type_defs, @typeName(T));
            const suffix = if (std.mem.eql(u8, ts_type, "bigint")) "n" else "";
            return std.fmt.comptimePrint("type: \"{s}\", min: {d}{s}, max: {d}{s}", .{
                ts_type, std.math.minInt(T), suffix, std.math.maxInt(T), suffix,
            });
        },
        else => return "type: \"" ++ tsType(type_defs, @typeName(T)) ++ "\"",
    }
}

fn isPkField(comptime entity: anytype, comptime name: []const u8) bool {
    inline for (entity.pk) |pk_name| {
        if (comptime std.mem.eql(u8, pk_name, name)) return true;
    }
    return false;
}

/// `export const <name>Restrictions = { ... };` for one completed entity
/// (`zigma.completeEntity`), one line per field in declaration order.
pub fn restrictionsFn(comptime type_defs: anytype, comptime name: []const u8, comptime entity: anytype) []const u8 {
    comptime var lines: []const u8 = "";
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
        const field = @field(entity.fields, field_name);
        const T = @field(type_defs, field.type).Type;
        const nullable = if (field.nullable and !isPkField(entity, field_name)) ", nullable: true" else "";
        lines = lines ++ "  " ++ field_name ++ ": { " ++ restrictionBody(type_defs, T) ++ nullable ++ " },\n";
    }
    return "export const " ++ name ++ "Restrictions: Record<string, Restriction> = {\n" ++ lines ++ "};";
}

/// The whole `check.ts` of a system: the prelude, then the restrictions of
/// every entity of `entity_defs` (as produced by `zigma.defineEntities`, not
/// yet completed), in declaration order, blank-line separated.
pub fn generateTsCheck(comptime type_defs: anytype, comptime entity_defs: anytype) []const u8 {
    @setEvalBranchQuota(100000);
    comptime var module: []const u8 = check_prelude;
    inline for (@typeInfo(@TypeOf(entity_defs)).@"struct".field_names) |entity_name| {
        const entity = @import("zigma").completeEntity(@field(entity_defs, entity_name));
        module = module ++ "\n\n" ++ restrictionsFn(type_defs, entity_name, entity);
    }
    return module;
}
