//! Generation of `rules.ts`, the typed TS face of a system's domain rules
//! compiled to WASM (see `examples/aida_rules_wasm.zig` for the module and
//! its contract). Sibling of `ts_backend_generator.zig`.
//!
//! A system registers its rules by name, each with its record and its Zig
//! function: `.{ .validarCargo = .{ .record = cargo, .rule = validarCargo } }`.
//! From them come the TS parameter type (the record's fields through
//! `tsType`), the conversion of the value for JSON (the fields that need one,
//! through `jsonEncode`) and the error names (the error set of the function,
//! plus the framework's "InvalidInput"), so nothing of a rule is written
//! twice.

const std = @import("std");
const tsType = @import("zig_type_map_ts").tsType;
const jsonEncode = @import("zig_type_map_json").jsonEncode;

/// The answer of the module when the JSON is not an instance of the record
/// (see `examples/aida_rules_wasm.zig`).
pub const invalid_input = "InvalidInput";

/// Rule name -> its PascalCase stem (same trick as `PascalHolder` in
/// ts_backend_generator.zig: a container-level const of a generated struct
/// is comptime-known from any caller).
fn PascalHolder(comptime name: []const u8) type {
    return struct {
        const value: [name.len]u8 = blk: {
            var out: [name.len]u8 = undefined;
            for (name, 0..) |c, i| out[i] = if (i == 0) std.ascii.toUpper(c) else c;
            break :blk out;
        };
    };
}

/// `{ a: string; b: bigint }`: the record's fields with their TS types.
fn recordObjectType(comptime type_defs: anytype, comptime rec: anytype) []const u8 {
    comptime var out: []const u8 = "{ ";
    inline for (@typeInfo(@TypeOf(rec)).@"struct".field_names, 0..) |field_name, i| {
        if (i > 0) out = out ++ "; ";
        out = out ++ field_name ++ ": " ++ tsType(type_defs, @field(rec, field_name).type);
    }
    return out ++ " }";
}

/// The error names of a rule: its explicit Zig error set, in the order the
/// compiler reports it.
fn ruleErrorNames(comptime name: []const u8, comptime rule: anytype) []const [:0]const u8 {
    const ret = @typeInfo(@TypeOf(rule)).@"fn".return_type orelse
        @compileError("rule '" ++ name ++ "': its return type must be an error union");
    if (@typeInfo(ret) != .error_union)
        @compileError("rule '" ++ name ++ "': its return type must be an error union");
    return @typeInfo(@typeInfo(ret).error_union.error_set).error_set.error_names orelse
        @compileError("rule '" ++ name ++ "': its error set must be explicit, not anyerror");
}

/// `"A" | "B" | "InvalidInput"`.
fn errorUnion(comptime name: []const u8, comptime rule: anytype) []const u8 {
    comptime var out: []const u8 = "";
    inline for (ruleErrorNames(name, rule)) |error_name| {
        out = out ++ "\"" ++ error_name ++ "\" | ";
    }
    return out ++ "\"" ++ invalid_input ++ "\"";
}

// ---- conversion for JSON, from the JSON map ----

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80;
}

/// The `jsonEncode` expression (written over `v`) applied to `path`: every
/// `v` that is a whole identifier is replaced.
fn applyEncode(comptime expr: []const u8, comptime path: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    inline for (expr, 0..) |c, i| {
        const whole = c == 'v' and
            (i == 0 or !isIdentChar(expr[i - 1])) and
            (i + 1 == expr.len or !isIdentChar(expr[i + 1]));
        out = out ++ if (whole) path else &[_]u8{c};
    }
    return out;
}

/// The members `f: <conversion>` of the fields of struct `T` (at `path`)
/// that need a conversion, comma separated; "" when none does.
fn structMembers(comptime type_defs: anytype, comptime T: type, comptime path: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types) |field_name, field_type| {
        if (encodedOfZig(type_defs, field_type, path ++ "." ++ field_name)) |encoded| {
            if (out.len > 0) out = out ++ ", ";
            out = out ++ field_name ++ ": " ++ encoded;
        }
    }
    return out;
}

/// The value at `path` of Zig type `T` converted for `JSON.stringify`, or
/// null when it goes as is: a struct is rebuilt with only its converted
/// fields replaced (`{ ...path, f: ... }`).
fn encodedOfZig(comptime type_defs: anytype, comptime T: type, comptime path: []const u8) ?[]const u8 {
    if (@typeInfo(T) == .@"struct") {
        const members = structMembers(type_defs, T, path);
        return if (members.len == 0) null else "{ ..." ++ path ++ ", " ++ members ++ " }";
    }
    const expr = jsonEncode(type_defs, @typeName(T)) orelse return null;
    return applyEncode(expr, path);
}

/// The rule's argument for `call`: `value` as is, or rebuilt with the fields
/// that need a conversion for JSON (from the JSON map, `jsonEncode`).
fn encodedRecord(comptime type_defs: anytype, comptime rec: anytype) []const u8 {
    comptime var members: []const u8 = "";
    inline for (@typeInfo(@TypeOf(rec)).@"struct".field_names) |field_name| {
        const T = @field(type_defs, @field(rec, field_name).type).Type;
        if (encodedOfZig(type_defs, T, "value." ++ field_name)) |encoded| {
            if (members.len > 0) members = members ++ ", ";
            members = members ++ field_name ++ ": " ++ encoded;
        }
    }
    return if (members.len == 0) "value" else "{ ...value, " ++ members ++ " }";
}

/// The typed TS function of one rule (and its error type): calls the WASM
/// export of the same name through the shared `call` of the module.
pub fn ruleFn(comptime type_defs: anytype, comptime name: []const u8, comptime rule_def: anytype) []const u8 {
    const error_type = &PascalHolder(name).value ++ "Error";
    return "export type " ++ error_type ++ " = " ++ errorUnion(name, rule_def.rule) ++ ";\n" ++
        "\n" ++
        "export function " ++ name ++ "(value: " ++ recordObjectType(type_defs, rule_def.record) ++ "): " ++ error_type ++ " | null {\n" ++
        "  return call(\"" ++ name ++ "\", " ++ encodedRecord(type_defs, rule_def.record) ++ ") as " ++ error_type ++ " | null;\n" ++
        "}";
}

/// Loads rules.wasm (next to the module) once, and the shared `call` that
/// speaks the module's contract: JSON in, error name ("" when it passes) out.
const prelude =
    \\import { readFileSync } from "node:fs";
    \\
    \\const { instance } = await WebAssembly.instantiate(readFileSync(new URL("./rules.wasm", import.meta.url)));
    \\const { memory, alloc } = instance.exports as unknown as { memory: WebAssembly.Memory; alloc(len: number): number };
    \\
    \\// Runs a rule over its record instance, sent as JSON (each rule has already
    \\// converted the fields JSON.stringify cannot handle as is). The module
    \\// answers "" when the instance passes, or the name of the error.
    \\function call(rule: string, value: unknown): string | null {
    \\  const input = new TextEncoder().encode(JSON.stringify(value));
    \\  const ptr = alloc(input.length);
    \\  if (ptr === 0) throw new Error("rules.wasm: out of memory");
    \\  new Uint8Array(memory.buffer, ptr, input.length).set(input);
    \\  const result = (instance.exports[rule] as (ptr: number, len: number) => bigint)(ptr, input.length);
    \\  const out = new Uint8Array(memory.buffer, Number(result >> 32n), Number(result & 0xffffffffn));
    \\  const name = new TextDecoder().decode(out);
    \\  return name === "" ? null : name;
    \\}
;

/// The whole `rules.ts` of a system: the prelude, then the function of every
/// rule of `rule_defs`, in declaration order, blank-line separated.
pub fn generateTsRules(comptime type_defs: anytype, comptime rule_defs: anytype) []const u8 {
    comptime var module: []const u8 = prelude;
    inline for (@typeInfo(@TypeOf(rule_defs)).@"struct".field_names) |name| {
        module = module ++ "\n\n" ++ ruleFn(type_defs, name, @field(rule_defs, name));
    }
    return module;
}
