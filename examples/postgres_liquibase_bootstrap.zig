//! Arranque versionado de AIDA: valida el snapshot aceptado en compilación
//! y solicita a Liquibase que aplique las migraciones versionadas en runtime.

const std = @import("std");
const liquibase = @import("zigma_liquibase_runner");
const schema_guard = @import("aida_schema_guard");

comptime {
    // El estado deseado en compilación debe coincidir con el snapshot aceptado versionado.
    _ = schema_guard;
}

pub fn main(init: std.process.Init) !void {
    const jdbc_url = init.environ_map.get("LIQUIBASE_URL") orelse {
        std.debug.print("LIQUIBASE_URL is required (for example jdbc:postgresql://localhost:5432/zigma_dev)\n", .{});
        return error.MissingLiquibaseUrl;
    };

    // El proceso hijo aplica solo changesets versionados. Nunca deriva una migración
    // comparando esta base de producción con las entidades actuales.
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
