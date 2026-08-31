//! EXAMPLE: prints the generated TypeScript test module for the aida DML
//! module to stdout. `zig build ts-backend` writes this to
//! zig-out/ts-backend/dml.test.ts and runs it with `node --test`.

const std = @import("std");
const aida = @import("aida");
const ts_backend_generator = @import("ts_backend_generator");

// Container-level const: comptime scope, same reason as print_ts_backend.zig.
const test_module = ts_backend_generator.generateTsBackendTests(aida.ts_sample_defs, aida.entity_defs);

pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{test_module});
    try stdout.flush();
}
