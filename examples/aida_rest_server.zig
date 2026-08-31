//! Complete Phase 3 composition: accepted Liquibase history first, then one
//! libpq connection and the generated AIDA REST API.

const std = @import("std");
const aida = @import("aida");
const aida_rest = @import("aida_rest");
const crud = @import("zigma_postgres_crud");
const libpq = @import("zigma_postgres_libpq");
const liquibase = @import("zigma_liquibase_runner");
const std_http = @import("zigma_std_http");
const schema_guard = @import("aida_schema_guard");

comptime {
    _ = schema_guard;
}

pub fn main(init: std.process.Init) !void {
    const database_url = init.environ_map.get("DATABASE_URL") orelse {
        std.debug.print("DATABASE_URL is required (for example postgresql://user:password@localhost:5432/zigma_dev)\n", .{});
        return error.MissingDatabaseUrl;
    };
    const jdbc_url = init.environ_map.get("LIQUIBASE_URL") orelse {
        std.debug.print("LIQUIBASE_URL is required (for example jdbc:postgresql://localhost:5432/zigma_dev)\n", .{});
        return error.MissingLiquibaseUrl;
    };
    const schema_name = init.environ_map.get("LIQUIBASE_SCHEMA") orelse "public";

    try liquibase.update(init.gpa, .{
        .executable = init.environ_map.get("LIQUIBASE_BIN") orelse "liquibase",
        .changelog_file = init.environ_map.get("LIQUIBASE_CHANGELOG") orelse "db/changelog-root.yaml",
        .jdbc_url = jdbc_url,
        .username = init.environ_map.get("LIQUIBASE_USERNAME"),
        .password = init.environ_map.get("LIQUIBASE_PASSWORD"),
        .schema_name = schema_name,
    });

    var connection = libpq.Connection.init(init.gpa);
    defer connection.deinit();
    try connection.connect(database_url);
    try setSearchPath(init.gpa, &connection, schema_name);

    const port = if (init.environ_map.get("HTTP_PORT")) |value|
        try std.fmt.parseInt(u16, value, 10)
    else
        8080;
    const address = init.environ_map.get("HTTP_ADDRESS") orelse "127.0.0.1";

    var api = aida_rest.Api.init(.{});
    var repository = crud.Repository(aida.entity_defs).init(&connection);
    std.debug.print("AIDA REST listening on http://{s}:{d}\n", .{ address, port });
    try std_http.serve(init.io, init.gpa, &api, &repository, .{
        .address = address,
        .port = port,
    });
}

fn setSearchPath(
    allocator: std.mem.Allocator,
    connection: *libpq.Connection,
    schema_name: []const u8,
) !void {
    var sql: std.ArrayList(u8) = .empty;
    defer sql.deinit(allocator);
    try sql.appendSlice(allocator, "SET search_path TO \"");
    for (schema_name) |byte| {
        try sql.append(allocator, byte);
        if (byte == '"') try sql.append(allocator, '"');
    }
    try sql.append(allocator, '"');
    try connection.exec(sql.items);
}
