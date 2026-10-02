//! Generation of `rules.ts`, the typed TS face of a system's domain rules
//! compiled to WASM (see `examples/aida_rules_wasm.zig` for the module and
//! its contract). Sibling of `ts_backend_generator.zig`.
//!
//! A system registers its rules by name, each with its record and its Zig
//! function: `.{ .validarCargo = .{ .record = cargo, .rule = validarCargo } }`.
//! From them come the TS parameter type (the record's fields through
//! `tsType`) and the error names (the error set of the function, plus the
//! framework's "InvalidInput"), so nothing of a rule is written twice.

const std = @import("std");
const tsType = @import("zig_type_map_ts").tsType;

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

/// The typed TS function of one rule (and its error type): calls the WASM
/// export of the same name through the shared `call` of the module.
pub fn ruleFn(comptime type_defs: anytype, comptime name: []const u8, comptime rule_def: anytype) []const u8 {
    const error_type = &PascalHolder(name).value ++ "Error";
    return "export type " ++ error_type ++ " = " ++ errorUnion(name, rule_def.rule) ++ ";\n" ++
        "\n" ++
        "export function " ++ name ++ "(value: " ++ recordObjectType(type_defs, rule_def.record) ++ "): " ++ error_type ++ " | null {\n" ++
        "  return call(\"" ++ name ++ "\", value) as " ++ error_type ++ " | null;\n" ++
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
    \\// Runs a rule over its record instance, sent as JSON (a bigint as an exact
    \\// number, which JSON.stringify alone rejects). The module answers "" when
    \\// the instance passes, or the name of the error.
    \\function call(rule: string, value: unknown): string | null {
    \\  const json = JSON.stringify(value, (_key, v) => (typeof v === "bigint" ? JSON.rawJSON(v.toString()) : v));
    \\  const input = new TextEncoder().encode(json);
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
