//! EXAMPLE: prints the generated `rules.ts` for the aida system to stdout.
//! `zig build rules-wasm` writes it to backend/src/rules.ts, next to the
//! rules.wasm it loads.

const std = @import("std");
const aida = @import("aida");
const ts_rules_generator = @import("ts_rules_generator");

// Container-level const: comptime scope, same reason as print_ts_backend.zig.
const rules_module = ts_rules_generator.generateTsRules(aida.type_defs, aida.rule_defs);

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{rules_module});
    try stdout.flush();
}
