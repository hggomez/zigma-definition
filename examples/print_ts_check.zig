//! EXAMPLE: prints the generated `check.ts` for the aida system to stdout.
//! `zig build ts-backend` writes it to backend/src/check.ts.

const std = @import("std");
const aida = @import("aida");
const ts_check_generator = @import("ts_check_generator");

// Container-level const: comptime scope, same reason as print_ts_backend.zig.
const check_module = ts_check_generator.generateTsCheck(aida.type_defs, aida.entity_defs);

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{check_module});
    try stdout.flush();
}
