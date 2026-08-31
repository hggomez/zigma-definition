//! EXAMPLE: prints the generated TypeScript DML module for the aida system to
//! stdout. `zig build ts-backend` writes this to zig-out/ts-backend/dml.ts.

const std = @import("std");
const aida = @import("aida");
const ts_backend_generator = @import("ts_backend_generator");

// A container-level const is always evaluated in comptime scope; calling
// generateTsBackend from inside main (runtime scope) only yields a runtime
// copy of the result, not comptime-known enough for its internal @field
// lookups (same reason as print_schema.zig).
const dml_module = ts_backend_generator.generateTsBackend(aida.ts_type_defs, aida.entity_defs);

// Writes to stdout, not std.debug.print (which always goes to stderr): the
// `ts-backend` build step captures this output to a file.
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}\n", .{dml_module});
    try stdout.flush();
}
