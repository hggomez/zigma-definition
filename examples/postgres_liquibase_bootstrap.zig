//! Versioned AIDA startup: validate the accepted snapshot at compilation and
//! ask Liquibase to apply committed migrations at runtime.

const std = @import("std");
const liquibase = @import("zigma_liquibase_runner");
const schema_guard = @import("aida_schema_guard");

comptime {
    _ = schema_guard;
}

pub fn main(init: std.process.Init) !void {
    const jdbc_url = init.environ_map.get("LIQUIBASE_URL") orelse {
        std.debug.print("LIQUIBASE_URL is required (for example jdbc:postgresql://localhost:5432/zigma_dev)\n", .{});
        return error.MissingLiquibaseUrl;
    };

    try liquibase.update(init.gpa, .{
        .executable = init.environ_map.get("LIQUIBASE_BIN") orelse "liquibase",
        .changelog_file = init.environ_map.get("LIQUIBASE_CHANGELOG") orelse "db/changelog-root.yaml",
        .jdbc_url = jdbc_url,
        .username = init.environ_map.get("LIQUIBASE_USERNAME"),
        .password = init.environ_map.get("LIQUIBASE_PASSWORD"),
        .schema_name = init.environ_map.get("LIQUIBASE_SCHEMA") orelse "public",
    });

    std.debug.print("AIDA Liquibase migrations applied successfully\n", .{});
}
