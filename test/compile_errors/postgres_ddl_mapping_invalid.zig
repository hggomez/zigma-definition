//! expected: 'sql_type' must be a non-empty string
const ddl = @import("zigma_postgres_ddl");

comptime {
    _ = ddl.defineTypeMappings(.{
        .text = .{ .sql_type = "" },
    });
}
