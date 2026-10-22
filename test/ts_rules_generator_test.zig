//! Tests for the generation of rules.ts, the TS half of the rules WASM
//! contract (src/rules_wasm.zig), driving `ts_rules_generator.zig`. rules.ts
//! loads ./rules.wasm (next to it) once, on import, and exposes each rule of
//! the system typed:
//! - its parameter, the TS type of the rule's parameter (`tsTypeOf`), the same
//!   type the WASM side parses;
//! - its result, `RuleResult<E>`: `{ ok: true } | { ok: false; error: E }`,
//!   with E the rule's Zig error names (sorted: the compiler's order is not
//!   stable) plus "InvalidInput";
//! - its serializer, field by field: only the fields of the parameter go into
//!   the JSON (TS lets an object with extra properties through, which the
//!   WASM side would reject), and a bigint goes as an exact JSON number
//!   (`JSON.rawJSON`; `JSON.stringify` throws on a bigint).

const std = @import("std");
const zigma = @import("zigma");
const test_system = @import("test_system");
const ts = @import("ts_rules_generator");
const expectEqualStrings = std.testing.expectEqualStrings;

// A record with every kind of field: string, boolean, number (an integer
// whose interval is exact in JS), bigint, and an object with a bigint inside.
const Period = struct { year: u16, total: i64 };

const types = zigma.defineTypes(.{
    .text = zigma.TypeDef{ .Type = []const u8 },
    .integer = zigma.TypeDef{ .Type = i64 },
    .boolean = zigma.TypeDef{ .Type = bool },
    .small = zigma.TypeDef{ .Type = u8 },
    .period = zigma.TypeDef{ .Type = Period },
});

const sample = zigma.record(types, .{
    .name = .{ .type = "text" },
    .active = .{ .type = "boolean" },
    .level = .{ .type = "small" },
    .count = .{ .type = "integer" },
    .period = .{ .type = "period" },
});

fn checkSample(s: zigma.RecordInstanceType(types, sample)) error{Inactive}!void {
    if (!s.active) return error.Inactive;
}

const sample_rules = zigma.defineRules(types, .{
    .checkSample = .{ .record = sample, .rule = checkSample },
});

test "ruleFn: the parameter typed and serialized field by field, a bigint as an exact JSON number" {
    try expectEqualStrings(
        \\export type CheckSampleError = "Inactive" | "InvalidInput";
        \\
        \\export function checkSample(value: { name: string; active: boolean; level: number; count: bigint; period: { year: number; total: bigint } }): RuleResult<CheckSampleError> {
        \\  return call("checkSample", { name: value.name, active: value.active, level: value.level, count: JSON.rawJSON(value.count.toString()), period: { year: value.period.year, total: JSON.rawJSON(value.period.total.toString()) } });
        \\}
        \\
    , ts.ruleFn("checkSample", sample_rules.checkSample));
}

test "ruleFn: the error names are sorted, InvalidInput last" {
    try expectEqualStrings(
        \\export type CheckBookingError = "Empty" | "EndBeforeStart" | "InvalidInput";
        \\
        \\export function checkBooking(value: { room: string; start: bigint; end: bigint }): RuleResult<CheckBookingError> {
        \\  return call("checkBooking", { room: value.room, start: JSON.rawJSON(value.start.toString()), end: JSON.rawJSON(value.end.toString()) });
        \\}
        \\
    , ts.ruleFn("checkBooking", test_system.rule_defs.checkBooking));
}

test "generateTsRules: the loader and the contract call, then every rule in declaration order" {
    try expectEqualStrings(
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
        \\export type CheckRoomError = "NoCapacity" | "InvalidInput";
        \\
        \\export function checkRoom(value: { room: string; capacity: bigint }): RuleResult<CheckRoomError> {
        \\  return call("checkRoom", { room: value.room, capacity: JSON.rawJSON(value.capacity.toString()) });
        \\}
        \\
        \\export type CheckBookingError = "Empty" | "EndBeforeStart" | "InvalidInput";
        \\
        \\export function checkBooking(value: { room: string; start: bigint; end: bigint }): RuleResult<CheckBookingError> {
        \\  return call("checkBooking", { room: value.room, start: JSON.rawJSON(value.start.toString()), end: JSON.rawJSON(value.end.toString()) });
        \\}
        \\
    , ts.generateTsRules(test_system.rule_defs));
}
