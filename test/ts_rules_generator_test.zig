//! Tests for the generation of `rules.ts`, the typed TS face of the domain
//! rules compiled to WASM, driving `ts_rules_generator.zig`. A rule is
//! registered by name with its record and its Zig function; from them come
//! the parameter type (the record's fields through `tsType`) and the error
//! names (the error set of the function, plus the framework's
//! "InvalidInput"), so nothing of the rule is written twice.

const std = @import("std");
const zigma = @import("zigma");
const ts = @import("ts_rules_generator");
const expectEqualStrings = std.testing.expectEqualStrings;

// producto: one field of each common type (text, integer -> bigint, boolean)
const producto = zigma.record(zigma.common_type_defs, .{
    .sku = .{ .type = "text" },
    .precio = .{ .type = "integer" },
    .activo = .{ .type = "boolean" },
});

fn validarProducto(p: zigma.RecordInstanceType(zigma.common_type_defs, producto)) error{ PrecioNegativo, SinSku }!void {
    if (p.sku.len == 0) return error.SinSku;
    if (p.precio < 0) return error.PrecioNegativo;
}

const rule_defs = .{
    .validarProducto = .{ .record = producto, .rule = validarProducto },
};

// Same comptime-scope trick as the other generator tests: each generation
// call is a container-level const.
const validar_producto_ts = ts.ruleFn(zigma.common_type_defs, "validarProducto", rule_defs.validarProducto);

test "ruleFn: a typed function per rule, its errors from the Zig error set plus InvalidInput" {
    try expectEqualStrings(
        \\export type ValidarProductoError = "PrecioNegativo" | "SinSku" | "InvalidInput";
        \\
        \\export function validarProducto(value: { sku: string; precio: bigint; activo: boolean }): ValidarProductoError | null {
        \\  return call("validarProducto", value) as ValidarProductoError | null;
        \\}
    , validar_producto_ts);
}

const rules_ts = ts.generateTsRules(zigma.common_type_defs, rule_defs);

test "generateTsRules: loads rules.wasm once, the shared call through memory, then every rule" {
    try expectEqualStrings(
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
        \\
        \\export type ValidarProductoError = "PrecioNegativo" | "SinSku" | "InvalidInput";
        \\
        \\export function validarProducto(value: { sku: string; precio: bigint; activo: boolean }): ValidarProductoError | null {
        \\  return call("validarProducto", value) as ValidarProductoError | null;
        \\}
    , rules_ts);
}
