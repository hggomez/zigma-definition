//! EXAMPLE: the aida domain rules compiled to WASM (`zig build rules-wasm`
//! writes it to backend/src/rules.wasm), so the backend runs the very same
//! Zig rules instead of rewriting them. Hand-written for `validarCargo` for
//! now; to be generated once there is a second rule to generalize from.
//!
//! The contract with JS (pinned by test/rules_wasm_test.zig): the input is
//! the record instance as UTF-8 JSON, written by JS into room it got from
//! `alloc`; each rule parses it into the instance type derived from the def,
//! runs, frees the input and returns a string packed as `ptr << 32 | len`:
//! "" when the instance passes, the Zig error name when the rule rejects it,
//! "InvalidInput" when the JSON is not an instance of the record.

const std = @import("std");
const aida = @import("aida");

const allocator = std.heap.wasm_allocator;

/// Room for `len` bytes of input; null (0 in JS) when out of memory.
export fn alloc(len: usize) ?[*]u8 {
    const buf = allocator.alloc(u8, len) catch return null;
    return buf.ptr;
}

fn result(s: []const u8) u64 {
    return (@as(u64, @intFromPtr(s.ptr)) << 32) | s.len;
}

/// Parses the JSON instance of `rec` (the de-anonymizing parse that the
/// business functions expect to have happened before them) and runs `rule`
/// on it.
fn runRule(comptime rec: anytype, comptime rule: anytype, ptr: [*]u8, len: usize) u64 {
    const input = ptr[0..len];
    defer allocator.free(input);
    const parsed = std.json.parseFromSlice(aida.DefinedType(rec), allocator, input, .{}) catch
        return result("InvalidInput");
    defer parsed.deinit();
    rule(parsed.value) catch |err| return result(@errorName(err));
    return result("");
}

export fn validarCargo(ptr: [*]u8, len: usize) u64 {
    return runRule(aida.cargo, aida.validarCargo, ptr, len);
}
