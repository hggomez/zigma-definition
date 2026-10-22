//! EXAMPLE: prints the generated HTTP server (server.ts) of the aida system to
//! stdout. `zig build http-docker` writes it to backend/src/server.ts, next to
//! dml.ts. For now it serves the list of every entity (GET /api/<entity>): the
//! HTTP layer grows from there, one operation at a time.

const std = @import("std");
const aida = @import("aida");
const ts_server_generator = @import("ts_server_generator");

// A container-level const is always evaluated in comptime scope (same reason
// as print_ts_backend.zig).
const server_module = ts_server_generator.generateTsServer(aida.type_defs, aida.entity_defs);

// Writes to stdout, not std.debug.print (which always goes to stderr): the
// build step captures this output to a file.
pub fn main(init: std.process.Init) !void {
    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}", .{server_module});
    try stdout.flush();
}
