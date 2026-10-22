//! rules.ts generation: the TS half of the rules WASM contract
//! (`rules_wasm.zig`), from the system's `rule_defs`. rules.ts loads
//! ./rules.wasm (next to it) once, on import, and exposes each rule typed:
//! its parameter is the TS type of the rule's parameter (`tsTypeOf`, the same
//! type the WASM side parses), its result a `RuleResult<E>`
//! (`{ ok: true } | { ok: false; error: E }`, E the rule's Zig error names
//! plus "InvalidInput").
//!
//! The value is serialized field by field: only the fields of the parameter go
//! into the JSON (TS lets an object with extra properties through, which the
//! WASM side would reject as "InvalidInput"), and a bigint goes as an exact
//! JSON number (`JSON.rawJSON`; `JSON.stringify` throws on a bigint).

const std = @import("std");
const zig_type_map_ts = @import("zig_type_map_ts");
const ts_backend_generator = @import("ts_backend_generator");
const TsType = zig_type_map_ts.TsType;
const tsTypeOf = zig_type_map_ts.tsTypeOf;
const tsText = ts_backend_generator.tsText;
const PascalHolder = ts_backend_generator.PascalHolder;

/// The start of rules.ts: the loading of rules.wasm, `RuleResult` and the
/// contract call that every rule goes through.
const header =
    \\import { readFileSync } from "node:fs";
    \\
    \\const { instance } = await WebAssembly.instantiate(readFileSync(new URL("./rules.wasm", import.meta.url)));
    \\const { memory, alloc } = instance.exports as unknown as { memory: WebAssembly.Memory; alloc(len: number): number };
    \\
    \\export type RuleResult<E extends string> = { ok: true } | { ok: false; error: E };
    \\
    \\// Runs a rule export of rules.wasm under the contract: the instance as JSON
    \\// into room got from alloc; the result, a string packed as ptr << 32 | len,
    \\// is "" when the instance passes, else the name of the error.
    \\function call<E extends string>(rule: string, value: unknown): RuleResult<E> {
    \\  const input = new TextEncoder().encode(JSON.stringify(value));
    \\  const ptr = alloc(input.length) >>> 0;
    \\  if (ptr === 0) throw new Error("rules.wasm: out of memory");
    \\  new Uint8Array(memory.buffer, ptr, input.length).set(input);
    \\  const packed = (instance.exports[rule] as (ptr: number, len: number) => bigint)(ptr, input.length);
    \\  const out = new Uint8Array(memory.buffer, Number(packed >> 32n), Number(packed & 0xffffffffn));
    \\  const name = new TextDecoder().decode(out);
    \\  return name === "" ? { ok: true } : { ok: false, error: name as E };
    \\}
    \\
;

/// The TS expression that serializes `access` (of type `t`) for the JSON:
/// itself, a bigint as an exact JSON number, an object rebuilt with only its
/// fields, recursively.
fn serializerText(comptime t: TsType, comptime access: []const u8) []const u8 {
    return switch (t) {
        .boolean, .string, .number => access,
        .bigint => "JSON.rawJSON(" ++ access ++ ".toString())",
        .object => |fields| blk: {
            var out: []const u8 = "{ ";
            for (fields, 0..) |field, i| {
                const sep = if (i > 0) ", " else "";
                out = out ++ sep ++ field.name ++ ": " ++ serializerText(field.type, access ++ "." ++ field.name);
            }
            break :blk out ++ " }";
        },
    };
}

/// The TS union of the error names of `ErrorSet`, sorted (the order the
/// compiler reports them in is not stable), then "InvalidInput". A
/// container-level const, so the text is comptime-known (same trick as
/// zigma's `LabelHolder`).
fn ErrorUnionHolder(comptime ErrorSet: type) type {
    return struct {
        const text: []const u8 = blk: {
            const names = @typeInfo(ErrorSet).error_set.error_names.?;
            var sorted: [names.len][]const u8 = undefined;
            for (names, 0..) |name, i| sorted[i] = name;
            for (1..sorted.len) |i| {
                var j = i;
                while (j > 0 and std.mem.order(u8, sorted[j], sorted[j - 1]) == .lt) : (j -= 1) {
                    std.mem.swap([]const u8, &sorted[j], &sorted[j - 1]);
                }
            }
            var out: []const u8 = "";
            for (sorted) |name| out = out ++ "\"" ++ name ++ "\" | ";
            break :blk out ++ "\"InvalidInput\"";
        };
    };
}

/// The TS of one rule as a container-level const, so it is comptime-known
/// also where `ruleFn` is called from a runtime scope.
fn RuleTsHolder(comptime rule_name: []const u8, comptime rule_def: anytype) type {
    return struct {
        const text: []const u8 = blk: {
            const fn_info = @typeInfo(@TypeOf(rule_def.rule)).@"fn";
            const param = tsTypeOf(fn_info.param_types[0].?);
            const ErrorSet = @typeInfo(fn_info.return_type.?).error_union.error_set;
            const pascal: []const u8 = &PascalHolder(rule_name).value;
            const error_type = pascal ++ "Error";
            break :blk "export type " ++ error_type ++ " = " ++ ErrorUnionHolder(ErrorSet).text ++ ";\n" ++
                "\n" ++
                "export function " ++ rule_name ++ "(value: " ++ tsText(param) ++ "): RuleResult<" ++ error_type ++ "> {\n" ++
                "  return call(\"" ++ rule_name ++ "\", " ++ serializerText(param, "value") ++ ");\n" ++
                "}\n";
        };
    };
}

/// The TS of one rule: its error type and its typed function, which
/// serializes the value and goes through the contract call.
pub fn ruleFn(comptime rule_name: []const u8, comptime rule_def: anytype) []const u8 {
    return RuleTsHolder(rule_name, rule_def).text;
}

/// The whole rules.ts of a system: the header, then every rule in
/// declaration order.
pub fn generateTsRules(comptime rule_defs: anytype) []const u8 {
    const rule_names = @typeInfo(@TypeOf(rule_defs)).@"struct".field_names;
    comptime var module: []const u8 = header;
    inline for (rule_names) |rule_name| {
        module = module ++ "\n" ++ RuleTsHolder(rule_name, @field(rule_defs, rule_name)).text;
    }
    return module;
}
