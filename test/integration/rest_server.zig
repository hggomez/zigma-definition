//! Test-only AIDA REST process. The surrounding integration script owns DDL
//! setup and teardown so this executable exercises only libpq + REST + HTTP.

const std = @import("std");
const aida = @import("aida");
const aida_rest = @import("aida_rest");
const crud = @import("zigma_postgres_crud");
const libpq = @import("zigma_postgres_libpq");
const std_http = @import("zigma_std_http");

pub fn main(init: std.process.Init) !void {
    const database_url = init.environ_map.get("DATABASE_URL") orelse return error.MissingDatabaseUrl;
    const port_text = init.environ_map.get("HTTP_PORT") orelse return error.MissingHttpPort;
    const port = try std.fmt.parseInt(u16, port_text, 10);

    var connection = libpq.Connection.init(init.gpa);
    defer connection.deinit();
    try connection.connect(database_url);

    var api = aida_rest.Api.init(.{ .max_body_bytes = 256 });
    var repository = crud.Repository(aida.entity_defs).init(&connection);
    std.debug.print("ready {d}\n", .{port});
    try std_http.serve(init.io, init.gpa, &api, &repository, .{
        .port = port,
        .max_body_bytes = 256,
    });
}
