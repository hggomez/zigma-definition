//! Runtime bootstrap for the compile-time AIDA PostgreSQL schema.
//!
//! `schema_ddl` is generated and validated while compiling this executable.
//! Only the connection and database side effect happen at runtime.

const std = @import("std");
const zigma = @import("zigma");
const aida = @import("aida");
const postgres_ddl = @import("zigma_postgres_ddl");
const postgres_executor = @import("zigma_postgres_executor");
const postgres_libpq = @import("zigma_postgres_libpq");
const schema_guard = @import("aida_schema_guard");

comptime {
    _ = schema_guard;
}

const type_mappings = postgres_ddl.defineTypeMappings(zigma.merge(.{
    postgres_ddl.common_type_mappings,
    .{
        .fecha = postgres_ddl.TypeMapping{ .sql_type = "DATE" },
        .email = postgres_ddl.TypeMapping{ .sql_type = "TEXT" },
    },
}));

const schema_ddl = postgres_ddl.createSchemaDdl(aida.entity_defs, type_mappings);

pub fn main(init: std.process.Init) !void {
    const database_url = init.environ_map.get("DATABASE_URL") orelse {
        std.debug.print("DATABASE_URL is required\n", .{});
        return error.MissingDatabaseUrl;
    };

    var connection = postgres_libpq.Connection.init(init.gpa);
    defer connection.deinit();

    connection.connect(database_url) catch |err| {
        printPostgresError(&connection, err);
        return err;
    };
    postgres_executor.executeSchema(&connection, schema_ddl) catch |err| {
        printPostgresError(&connection, err);
        return err;
    };

    std.debug.print("AIDA PostgreSQL schema applied successfully\n", .{});
}

fn printPostgresError(connection: *const postgres_libpq.Connection, err: anyerror) void {
    if (connection.lastError()) |message| {
        std.debug.print("PostgreSQL {t}: {s}\n", .{ err, message });
    } else {
        std.debug.print("PostgreSQL {t}\n", .{err});
    }
}
