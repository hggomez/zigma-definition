//! Prints the generated rules.ts of the test system (test/test_system.zig) to
//! stdout. `zig build test-rules-wasm` writes it next to the system's compiled
//! rules, as rules.ts + rules.wasm, for test/rules_ts_node_test.zig.

const std = @import("std");
const test_system = @import("test_system");
const ts_rules_generator = @import("ts_rules_generator");

// A container-level const is always evaluated in comptime scope (same reason
// as examples/print_ts_backend.zig).
const rules_module = ts_rules_generator.generateTsRules(test_system.rule_defs);

// Writes to stdout, not std.debug.print (which always goes to stderr): the
// build step captures this output to a file.
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}", .{rules_module});
    try stdout.flush();
}
