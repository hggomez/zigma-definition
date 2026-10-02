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
    // the value is converted for JSON field by field, from the JSON map
    // (`jsonEncode`): only the fields that need it (precio is an i64)
    try expectEqualStrings(
        \\export type ValidarProductoError = "PrecioNegativo" | "SinSku" | "InvalidInput";
        \\
        \\export function validarProducto(value: { sku: string; precio: bigint; activo: boolean }): ValidarProductoError | null {
        \\  return call("validarProducto", { ...value, precio: JSON.rawJSON(value.precio.toString()) }) as ValidarProductoError | null;
        \\}
    , validar_producto_ts);
}

// envio: struct-backed fields. `medida` has an i64 inside (converted inside
// the nested object); `origen` has nothing to convert (not mentioned).
const Medida = struct { largo: i64, ancho: u8 };
const Punto = struct { x: i16, y: u16 };
const envio_type_defs = zigma.defineTypes(zigma.merge(.{ zigma.common_type_defs, .{
    .medida = zigma.TypeDef{ .Type = Medida },
    .punto = zigma.TypeDef{ .Type = Punto },
} }));
const envio = zigma.record(envio_type_defs, .{
    .id = .{ .type = "text" },
    .medida = .{ .type = "medida" },
    .origen = .{ .type = "punto" },
});

fn validarEnvio(e: zigma.RecordInstanceType(envio_type_defs, envio)) error{EnvioVacio}!void {
    if (e.medida.largo == 0) return error.EnvioVacio;
}

const validar_envio_ts = ts.ruleFn(envio_type_defs, "validarEnvio", .{ .record = envio, .rule = validarEnvio });

test "ruleFn: a struct field is converted inside its object, and one with nothing to convert is not mentioned" {
    try expectEqualStrings(
        \\export type ValidarEnvioError = "EnvioVacio" | "InvalidInput";
        \\
        \\export function validarEnvio(value: { id: string; medida: { largo: bigint; ancho: number }; origen: { x: number; y: number } }): ValidarEnvioError | null {
        \\  return call("validarEnvio", { ...value, medida: { ...value.medida, largo: JSON.rawJSON(value.medida.largo.toString()) } }) as ValidarEnvioError | null;
        \\}
    , validar_envio_ts);
}

// nombre: nothing to convert at all, the value goes as is
const nombre = zigma.record(zigma.common_type_defs, .{
    .nombre = .{ .type = "text" },
});

fn validarNombre(n: zigma.RecordInstanceType(zigma.common_type_defs, nombre)) error{NombreVacio}!void {
    if (n.nombre.len == 0) return error.NombreVacio;
}

const validar_nombre_ts = ts.ruleFn(zigma.common_type_defs, "validarNombre", .{ .record = nombre, .rule = validarNombre });

test "ruleFn: a record with nothing to convert passes the value as is" {
    try expectEqualStrings(
        \\export type ValidarNombreError = "NombreVacio" | "InvalidInput";
        \\
        \\export function validarNombre(value: { nombre: string }): ValidarNombreError | null {
        \\  return call("validarNombre", value) as ValidarNombreError | null;
        \\}
    , validar_nombre_ts);
}

const rules_ts = ts.generateTsRules(zigma.common_type_defs, rule_defs);

test "generateTsRules: loads rules.wasm once, the shared call through memory, then every rule" {
    try expectEqualStrings(
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
        \\
        \\export type ValidarProductoError = "PrecioNegativo" | "SinSku" | "InvalidInput";
        \\
        \\export function validarProducto(value: { sku: string; precio: bigint; activo: boolean }): ValidarProductoError | null {
        \\  return call("validarProducto", { ...value, precio: JSON.rawJSON(value.precio.toString()) }) as ValidarProductoError | null;
        \\}
    , rules_ts);
}
