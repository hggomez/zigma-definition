//! Verificación comptime del snapshot del consumidor, sin depender de su Model.
const std = @import("std");
const postgres = @import("application_postgres");

// El build inyecta el archivo del consumidor como recurso. No se lee el historial
// incluido en el paquete Zigma ni se necesita acceder a archivos en runtime.
const accepted_snapshot = @embedFile("accepted_snapshot");

comptime {
    if (!std.mem.eql(u8, postgres.schema_snapshot, accepted_snapshot))
        @compileError("PostgreSQL schema differs from db/schema.snapshot.json; run 'zig build migration'");
}
