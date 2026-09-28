//! Tipos compartidos por el controlador, los adaptadores y los repositorios actuales.
//! Las declaraciones viven aquí para evitar imports circulares; api.zig conserva
//! sus nombres públicos. Los resultados siguen usando celdas de texto o null.

const std = @import("std");

pub const Method = enum { GET, POST, PUT, DELETE, other };

/// Vista de solicitud independiente del transporte. Todos los slices pueden ser
/// prestados porque `handle` los consume en forma síncrona antes de retornar.
pub const Request = struct {
    method: Method,
    target: []const u8,
    content_type: ?[]const u8 = null,
    body: []const u8 = "",
};

/// El cuerpo de respuesta pertenece al allocator pasado a `handle`.
pub const Response = struct {
    status: u16,
    body: []const u8,
    content_type: []const u8 = "application/json",
};

/// Metadatos de rutas en compilación para adaptadores, tests y documentación futura.
/// El despacho es código generado y no recorre este array.
pub const Route = struct {
    path: []const u8,
    methods: [4]Method = .{ .GET, .POST, .PUT, .DELETE },
};

/// Parámetro PostgreSQL validado. null de Zig representa SQL NULL;
/// los bytes "null" siguen siendo un valor de texto común.
pub const FieldValue = struct {
    name: []const u8,
    value: ?[]const u8,
};

/// Resultado tabular mínimo con memoria propia, usado por repositorios y dobles de prueba.
pub const QueryResult = struct {
    allocator: std.mem.Allocator,
    columns: []const []const u8,
    rows: []const []const ?[]const u8,

    pub fn deinit(self: QueryResult) void {
        // El resultado contiene copias propias: nombres de columnas, arrays de filas
        // y celdas no-null se copiaron al allocator del resultado.
        for (self.columns) |column| self.allocator.free(column);
        self.allocator.free(self.columns);
        for (self.rows) |row| {
            for (row) |value| if (value) |bytes| self.allocator.free(bytes);
            self.allocator.free(row);
        }
        self.allocator.free(self.rows);
    }
};

pub const RepositoryError = error{
    OutOfMemory,
    Conflict,
    Unavailable,
    DatabaseError,
};

pub const Config = struct {
    // La capa pura impone este límite aunque el adaptador de red tenga uno propio.
    max_body_bytes: usize = 1024 * 1024,
};
