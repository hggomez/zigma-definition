//! Test of the aida domain rules compiled to WASM (`backend/src/rules.wasm`),
//! called from Node: the same Zig rule (`aida.validarCargo`) the Zig code
//! uses, run by the backend's JavaScript engine. Needs Node, not Docker.
//!
//! The contract between JS and the module, pinned here:
//! * `alloc(len) -> ptr`: room in the module's memory for the input.
//! * `validarCargo(ptr, len) -> u64`: the input is the record instance as
//!   UTF-8 JSON; the module parses it into `aida.DefinedType(aida.cargo)`,
//!   runs the rule and frees the input. The result is a string packed as
//!   `ptr << 32 | len`: "" when the instance passes, the Zig error name when
//!   the rule rejects it, "InvalidInput" when the JSON is not an instance of
//!   the record.
//!
//! Run with `zig build rules-wasm`.

const std = @import("std");

// Loads the module and calls the rule through the contract above. Prints
// RULES_OK when every case holds.
const validar_cargo_script =
    \\import { readFileSync } from 'node:fs';
    \\import { strictEqual } from 'node:assert';
    \\const { instance } = await WebAssembly.instantiate(readFileSync('./src/rules.wasm'));
    \\const { memory, alloc, validarCargo } = instance.exports;
    \\const call = (rule, value) => {
    \\  const input = new TextEncoder().encode(JSON.stringify(value));
    \\  const ptr = alloc(input.length);
    \\  new Uint8Array(memory.buffer, ptr, input.length).set(input);
    \\  const packed = rule(ptr, input.length);
    \\  const out = new Uint8Array(memory.buffer, Number(packed >> 32n), Number(packed & 0xffffffffn));
    \\  return new TextDecoder().decode(out);
    \\};
    \\strictEqual(call(validarCargo, { cargo: 'TIT', denominacion: 'Titular', orden: 1, puede_dirigir: true }),
    \\  '', 'un titular puede dirigir');
    \\strictEqual(call(validarCargo, { cargo: 'AY1', denominacion: 'Ayudante de primera', orden: 5, puede_dirigir: true }),
    \\  'AyudanteNoPuedeDirigir', 'un ayudante no puede dirigir');
    \\strictEqual(call(validarCargo, { cargo: 'AY1', denominacion: 'Ayudante de primera', orden: 5, puede_dirigir: false }),
    \\  '', 'un ayudante que no dirige es válido');
    \\strictEqual(call(validarCargo, { cargo: 'TIT', denominacion: 'Titular', orden: 1 }),
    \\  'InvalidInput', 'si falta un campo no es una instancia del record');
    \\strictEqual(call(validarCargo, { cargo: 'TIT', denominacion: 'Titular', orden: 'uno', puede_dirigir: true }),
    \\  'InvalidInput', 'un campo con un tipo incorrecto no es una instancia del record');
    \\console.log('RULES_OK');
;

// The typed TS face of the module, `backend/src/rules.ts`: it loads
// rules.wasm once and exposes each rule as a function over the record
// instance (TS types from the def: `orden` is i64, hence `bigint`) that
// returns null when the instance passes, or the name of the domain error.
// A bigint travels in the JSON as an exact number (`JSON.rawJSON`, not
// `JSON.stringify`, which throws on a bigint): the largest i64 passes and one
// past it is not an i64, so it is "InvalidInput". Prints RULES_TS_OK.
const rules_ts_script =
    \\import { validarCargo } from './src/rules.ts';
    \\import { strictEqual } from 'node:assert';
    \\const titular = { cargo: 'TIT', denominacion: 'Titular', orden: 1n, puede_dirigir: true };
    \\strictEqual(validarCargo(titular), null, 'un titular puede dirigir');
    \\strictEqual(validarCargo({ cargo: 'AY1', denominacion: 'Ayudante de primera', orden: 5n, puede_dirigir: true }),
    \\  'AyudanteNoPuedeDirigir', 'un ayudante no puede dirigir');
    \\strictEqual(validarCargo({ ...titular, orden: 2n ** 63n - 1n }), null,
    \\  'el i64 más grande viaja exacto');
    \\strictEqual(validarCargo({ ...titular, orden: 2n ** 63n }), 'InvalidInput',
    \\  'uno más que el i64 más grande no es un i64');
    \\console.log('RULES_TS_OK');
;

/// Runs `script` with node from `backend/` and expects exit 0 and `marker` on
/// stdout; on failure dumps node's stdout/stderr.
fn expectNodeScriptOk(script: []const u8, marker: []const u8) !void {
    const result = std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "node", "--input-type=module", "-e", script },
        .cwd = .{ .path = "backend" },
        .stdout_limit = .limited(1 << 20),
        .stderr_limit = .limited(1 << 20),
    }) catch |err| {
        std.debug.print("could not run node: {s}\n", .{@errorName(err)});
        return err;
    };
    defer std.testing.allocator.free(result.stdout);
    defer std.testing.allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0) {
        std.debug.print(
            "node exited {any}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n",
            .{ result.term, result.stdout, result.stderr },
        );
        return error.NodeScriptFailed;
    }

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, marker) != null);
}

test "validarCargo compiled to WASM runs from Node with the same result as in Zig" {
    try expectNodeScriptOk(validar_cargo_script, "RULES_OK");
}

test "rules.ts exposes validarCargo typed, returning null or the domain error" {
    try expectNodeScriptOk(rules_ts_script, "RULES_TS_OK");
}
