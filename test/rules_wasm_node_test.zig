//! The rules of the test system compiled to a real wasm32 module and called
//! from Node: what the native test (rules_wasm_test.zig) cannot reach, i.e.
//! the exports by name, `alloc`, the packing of the result and that each call
//! frees its input. The script below is the TS half of the contract written by
//! hand (what rules.ts will generate): ask `alloc` for room, write the JSON
//! instance there, call the rule, unpack `ptr << 32 | len` and read the
//! string.
//!
//! Run with `zig build test-rules-wasm`, which compiles the module and passes its
//! path here. Not part of `zig build test` (needs Node).

const std = @import("std");
const build_options = @import("build_options");

// An ES module run with `node --input-type=module -e`; the path of the .wasm
// is its first argument. Prints RULES_WASM_OK when every assert holds.
const script =
    \\import { readFileSync } from 'node:fs';
    \\import assert from 'node:assert/strict';
    \\
    \\const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[1]));
    \\const { memory, alloc } = instance.exports;
    \\
    \\// the exports: the memory, alloc and one function per rule, named like it;
    \\// nothing else but __stack_pointer, a build artifact (rdynamic, which keeps
    \\// the rule exports, also exports the stack global) that is not contract
    \\const exports = Object.keys(instance.exports).filter((name) => name !== '__stack_pointer');
    \\assert.deepEqual(exports.sort(), ['alloc', 'checkBooking', 'checkRoom', 'memory']);
    \\
    \\function call(rule, json) {
    \\  const input = new TextEncoder().encode(json);
    \\  const ptr = alloc(input.length);
    \\  assert.notEqual(ptr, 0, 'alloc: out of memory');
    \\  new Uint8Array(memory.buffer, ptr, input.length).set(input);
    \\  const packed = instance.exports[rule](ptr, input.length);
    \\  const out = new Uint8Array(memory.buffer, Number(packed >> 32n), Number(packed & 0xffffffffn));
    \\  return new TextDecoder().decode(out);
    \\}
    \\
    \\// passes
    \\assert.equal(call('checkRoom', '{"room": "A", "capacity": 10}'), '');
    \\assert.equal(call('checkBooking', '{"room": "A", "start": 9, "end": 11}'), '');
    \\
    \\// rejected: the name of the domain error
    \\assert.equal(call('checkRoom', '{"room": "A", "capacity": 0}'), 'NoCapacity');
    \\assert.equal(call('checkBooking', '{"room": "A", "start": 11, "end": 9}'), 'EndBeforeStart');
    \\assert.equal(call('checkBooking', '{"room": "A", "start": 9, "end": 9}'), 'Empty');
    \\
    \\// not an instance of the record (including empty input)
    \\assert.equal(call('checkRoom', ''), 'InvalidInput');
    \\assert.equal(call('checkRoom', '{"room": "A"}'), 'InvalidInput');
    \\assert.equal(call('checkRoom', '{"room": "A", "capacity": "ten"}'), 'InvalidInput');
    \\
    \\// the whole i64 range crosses exactly, and nothing outside it
    \\assert.equal(call('checkRoom', '{"room": "A", "capacity": 9223372036854775807}'), '');
    \\assert.equal(call('checkRoom', '{"room": "A", "capacity": 9223372036854775808}'), 'InvalidInput');
    \\
    \\// each call frees its input and its parse: many calls do not grow the memory
    \\for (let i = 0; i < 10; i++) call('checkBooking', '{"room": "A", "start": 1, "end": 2}');
    \\const before = memory.buffer.byteLength;
    \\for (let i = 0; i < 10000; i++) call('checkBooking', '{"room": "A", "start": 1, "end": 2}');
    \\assert.equal(memory.buffer.byteLength, before, 'repeated calls grow the memory: something is not freed');
    \\
    \\console.log('RULES_WASM_OK');
;

test "the test system's rules compiled to wasm32 run from Node under the contract" {
    const result = std.process.run(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "node", "--input-type=module", "-e", script, build_options.wasm_path },
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
        return error.RulesWasmFailed;
    }

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "RULES_WASM_OK") != null);
}
