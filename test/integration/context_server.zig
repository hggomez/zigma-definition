//! Transporte real con un proveedor controlado: cada solicitud tiene su contexto.
const std = @import("std");
const rest = @import("zigma_rest");
const std_http = @import("zigma_std_http");

const Context = struct { sequence: usize };
const Provider = struct {
    calls: usize = 0,

    pub fn get(self: *@This()) !Context {
        self.calls += 1;
        if (self.calls == 3) return error.PrivateClockFailure;
        return .{ .sequence = self.calls };
    }
};

const Api = struct {
    pub const ValidationContext = Context;

    pub fn handle(_: *@This(), allocator: std.mem.Allocator, calls: *usize, _: rest.Request, context: Context) !rest.Response {
        calls.* += 1;
        return .{
            .status = 200,
            .body = try std.fmt.allocPrint(allocator, "{{\"sequence\":{d},\"api_calls\":{d}}}", .{ context.sequence, calls.* }),
        };
    }
};

pub fn main(init: std.process.Init) !void {
    const port = try std.fmt.parseInt(u16, init.environ_map.get("HTTP_PORT") orelse return error.MissingPort, 10);
    var api: Api = .{};
    var calls: usize = 0;
    var provider: Provider = .{};
    try std_http.serve(init.io, init.gpa, &api, &calls, &provider, .{ .port = port, .max_requests = 4 });
}
