//! Inicialización en runtime del schema PostgreSQL de AIDA generado en compilación.
//!
//! `schema_ddl` se genera y valida al compilar este ejecutable.
//! Solo la conexión y los efectos sobre la base de datos ocurren en runtime.

const std = @import("std");
const zigma = @import("zigma");
const aida = @import("aida");
const postgres_ddl = @import("zigma_postgres_ddl");
const postgres_executor_ddl = @import("zigma_postgres_executor_ddl");
const postgres_libpq = @import("zigma_postgres_libpq");
const schema_guard = @import("aida_schema_guard");

comptime {
    // Convierte un snapshot aceptado desactualizado en un error de compilación,
    // aunque este ejecutable use DDL CREATE TABLE directo en runtime y no Liquibase.
    _ = schema_guard;
}

// Todo esto sigue siendo información comptime: la proyección de dominios a SQL
// produce un string de schema inmutable y validado, incorporado al ejecutable.
const type_mappings = postgres_ddl.defineTypeMappings(zigma.merge(.{
    postgres_ddl.common_type_mappings,
    .{
        .fecha = postgres_ddl.TypeMapping{ .sql_type = "DATE" },
        .email = postgres_ddl.TypeMapping{ .sql_type = "TEXT" },
    },
}));

const schema_ddl = postgres_ddl.createSchemaDdl(aida.Model, type_mappings);

pub fn main(init: std.process.Init) !void {
    // El acceso al ambiente, la reserva de memoria, la conexión y la ejecución de SQL
    // ocurren recién después de que arranca el programa compilado.
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
    // El ejecutor genérico coordina la transacción; libpq se ocupa del transporte.
    postgres_executor_ddl.executeSchema(&connection, schema_ddl) catch |err| {
        printPostgresError(&connection, err);
        return err;
    };

    std.debug.print("AIDA PostgreSQL schema applied successfully\n", .{});
}

fn printPostgresError(connection: *const postgres_libpq.Connection, err: anyerror) void {
    // Los errores estables de Zig sirven para controlar el flujo; lastError agrega
    // el diagnóstico de PostgreSQL legible para el operador.
    if (connection.lastError()) |message| {
        std.debug.print("PostgreSQL {t}: {s}\n", .{ err, message });
    } else {
        std.debug.print("PostgreSQL {t}\n", .{err});
    }
}
