//! The rules of a system compiled to one WASM module. Generic: it exports the
//! rules of whatever module `build.zig` gives it as "system" (which exposes
//! `rule_defs`, declared with `zigma.defineRules`), one export per rule,
//! named like the rule.
//!
//! The contract with the caller (the TS backend): the input is the record
//! instance as UTF-8 JSON, written into room got from the exported `alloc`;
//! each rule export takes its pointer and length, frees it, and returns a
//! string packed as `ptr << 32 | len`: "" when the instance passes, the name
//! of the Zig error when the rule rejects it, "InvalidInput" when the JSON is
//! not an instance of the rule's record. The result strings are constants, so
//! the caller frees nothing.

const std = @import("std");
const builtin = @import("builtin");
const system = @import("system");

/// What each export does between reading its input and packing its result:
/// parses `input` into the instance type of the rule's record (the type of
/// the rule's parameter, which `defineRules` checked) and runs the rule.
/// Frees what it parses; `input` is the caller's.
pub fn run(allocator: std.mem.Allocator, comptime rule_name: []const u8, input: []const u8) []const u8 {
    const rule = @field(system.rule_defs, rule_name).rule;
    const Instance = @typeInfo(@TypeOf(rule)).@"fn".param_types[0].?;
    const parsed = std.json.parseFromSlice(Instance, allocator, input, .{}) catch
        return "InvalidInput";
    defer parsed.deinit();
    rule(parsed.value) catch |err| return @errorName(err);
    return "";
}

// The exports only exist on wasm: the packing assumes 32-bit pointers, and
// `wasm_allocator` is the allocator of the module's linear memory.
const wasm_allocator = std.heap.wasm_allocator;

/// Where an empty input "is": a real address of the module's memory. An
/// allocation of 0 bytes does not reserve memory and its pointer is not an
/// address the caller can write to (0xFFFFFFFF on wasm32).
var empty_input: [1]u8 = undefined;

/// Room for `len` bytes of input; null (0 for the caller) when out of memory.
fn alloc(len: usize) callconv(.c) ?[*]u8 {
    if (len == 0) return &empty_input;
    const buf = wasm_allocator.alloc(u8, len) catch return null;
    return buf.ptr;
}

fn pack(s: []const u8) u64 {
    return (@as(u64, @intFromPtr(s.ptr)) << 32) | s.len;
}

/// The export of one rule of `system.rule_defs`.
fn RuleExport(comptime rule_name: []const u8) type {
    return struct {
        fn call(ptr: [*]u8, len: usize) callconv(.c) u64 {
            const input = ptr[0..len];
            // an empty input was not allocated (see `alloc`)
            defer if (len != 0) wasm_allocator.free(input);
            return pack(run(wasm_allocator, rule_name, input));
        }
    };
}

comptime {
    if (builtin.target.cpu.arch.isWasm()) {
        @export(&alloc, .{ .name = "alloc" });
        for (@typeInfo(@TypeOf(system.rule_defs)).@"struct".field_names) |rule_name| {
            @export(&RuleExport(rule_name).call, .{ .name = rule_name });
        }
    }
}
