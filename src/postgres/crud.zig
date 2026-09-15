//! CRUD PostgreSQL parametrizado, derivado de las entidades Zigma.
//!
//! Solo entran en SQL identificadores de tablas y columnas conocidos en comptime.
//! Cada valor de la solicitud se pasa por separado mediante parámetros `$n`.

const std = @import("std");
const rest = @import("zigma_rest");

fn baseType(comptime T: type) type {
    // Los bindings del repositorio suelen contener `*Connection`. Los métodos se
    // declaran en `Connection`: se quita un nivel de puntero antes de la reflexión,
    // pero también se admite un doble de prueba que no sea un puntero.
    return switch (@typeInfo(T)) {
        .pointer => |pointer| pointer.child,
        else => T,
    };
}

fn queryResultType(comptime ConnectionType: type) type {
    // La conexión es estructural y no se importa desde libpq. Se obtiene su declaración
    // `queryParams` y se deriva el tipo de resultado exitoso para que el repositorio
    // devuelva el resultado nativo del driver con su memoria propia, sin copiarlo.
    const function_type = @TypeOf(@field(baseType(ConnectionType), "queryParams"));
    const return_type = @typeInfo(function_type).@"fn".return_type orelse
        @compileError("queryParams must have a return type");
    const return_info = @typeInfo(return_type);
    // Una llamada a la base debe poder fallar. Se rechaza un retorno sin errores con
    // un diagnóstico de contrato específico, antes de fallar más adelante en un `catch`.
    if (return_info != .error_union)
        @compileError("queryParams must return an error union containing an owned tabular result");
    return return_info.error_union.payload;
}

fn appendIdentifier(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    identifier: []const u8,
) std.mem.Allocator.Error!void {
    // Los identificadores PostgreSQL no pueden ser parámetros `$n`. Su seguridad
    // depende de la lista permitida por la SSOT y del escape estándar de comillas dobles.
    try output.append(allocator, '"');
    for (identifier) |byte| {
        // Copia cada byte del identificador confiable y duplica las comillas internas.
        try output.append(allocator, byte);
        if (byte == '"') try output.append(allocator, '"');
    }
    try output.append(allocator, '"');
}

fn appendParameter(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    number: usize,
) std.mem.Allocator.Error!void {
    // El texto del placeholder es pequeño y acotado: se formatea en la pila
    // para evitar reservar un string temporal por cada `$n`.
    var buffer: [32]u8 = undefined;
    // En los destinos soportados, los dígitos decimales de `usize` caben en este
    // buffer; llegar a NoSpace indicaría un estado imposible.
    const text = std.fmt.bufPrint(&buffer, "${d}", .{number}) catch unreachable;
    try output.appendSlice(allocator, text);
}

fn findValue(values: []const rest.FieldValue, name: []const u8) ?rest.FieldValue {
    // Las entradas son listas cortas de campos: una búsqueda lineal es más simple
    // que un mapa en runtime y mantiene la memoria en la arena de la solicitud.
    for (values) |value|
        if (std.mem.eql(u8, value.name, name)) return value;
    return null;
}

fn hasUnknownOrDuplicate(comptime entity: anytype, values: []const rest.FieldValue) bool {
    // REST ya valida estas invariantes, pero el repositorio concreto también tiene
    // una interfaz pública. Repetir las comprobaciones impide que una llamada directa
    // introduzca en SQL un identificador recibido en runtime.
    for (values, 0..) |value, index| {
        var known = false;
        // Compara solo contra la lista de nombres de campos permitidos en comptime.
        inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
            if (std.mem.eql(u8, value.name, field_name)) known = true;
        }
        if (!known) return true;
        // Recorre solo las entradas posteriores para considerar una vez cada par duplicado.
        for (values[index + 1 ..]) |later|
            if (std.mem.eql(u8, value.name, later.name)) return true;
    }
    return false;
}

fn appendWhere(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    parameters: *std.ArrayList(?[]const u8),
    comptime entity: anytype,
    filters: []const rest.FieldValue,
) std.mem.Allocator.Error!void {
    // Los filtros vacíos no generan cláusula WHERE. Quien llama decide si eso es
    // válido: GET lo permite; UPDATE y DELETE lo rechazan.
    if (filters.len == 0) return;
    try output.appendSlice(allocator, " WHERE ");
    var emitted: usize = 0;
    // Recorre los campos del schema, no el orden de la URL. Así el orden de SQL y
    // parámetros es determinista y los nombres recibidos no se usan como identificadores.
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
        if (findValue(filters, field_name)) |filter| {
            if (emitted != 0) try output.appendSlice(allocator, " AND ");
            try appendIdentifier(allocator, output, field_name);
            try output.appendSlice(allocator, " = ");
            // Agrega primero el valor al vector de parámetros: su longitud, contada desde uno,
            // es exactamente el número del placeholder de PostgreSQL.
            try parameters.append(allocator, filter.value);
            try appendParameter(allocator, output, parameters.items.len);
            emitted += 1;
        }
    }
}

fn mapDatabaseError(connection: anytype, err: anyerror) rest.RepositoryError {
    // Reduce los fallos propios del driver al vocabulario acotado del repositorio REST.
    // Los diagnósticos de PostgreSQL quedan privados.
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.NotConnected, error.ConnectionFailed => error.Unavailable,
        error.PostgresError => blk: {
            // Los dos primeros bytes de SQLSTATE identifican una clase estándar de error.
            if (connection.lastSqlState()) |state| {
                if (state.len >= 2) {
                    // La clase 23 cubre violaciones de PK, UK, FK, NOT NULL y otras
                    // restricciones
                    // de integridad que se representan naturalmente con HTTP 409.
                    if (state[0] == '2' and state[1] == '3')
                        break :blk error.Conflict;
                    // La clase 08 representa excepciones de conexión y se traduce como
                    // indisponibilidad del servicio, en lugar de un fallo interno.
                    if (state[0] == '0' and state[1] == '8')
                        break :blk error.Unavailable;
                }
            }
            break :blk error.DatabaseError;
        },
        else => error.DatabaseError,
    };
}

/// Crea una fábrica de repositorios para un sistema completo de entidades Zigma.
///
/// La conexión sigue siendo estructural: se puede vincular cualquier puntero que
/// exponga `queryParams` y `lastSqlState`. Esto mantiene los tests y un futuro
/// adaptador pg.zig independientes de libpq.
pub fn Repository(comptime Model: type) type {
    // El modelo compartido ya validó el contrato y normalizó campos, PKs y FKs.
    const model_info = Model.info;

    // Este tipo de fábrica exterior no tiene campos. Pospone la elección de la
    // implementación de conexión hasta la composición en runtime, pero conserva
    // esa elección visible para el sistema de tipos de Zig.
    return struct {
        pub fn init(connection: anytype) Bound(@TypeOf(connection)) {
            // El tipo de retorno se especializa a partir del argumento. Una conexión falsa
            // y libpq producen tipos de repositorio distintos sin costo adicional,
            // mediante el mismo constructor.
            return .{ .connection = connection };
        }

        pub fn Bound(comptime ConnectionType: type) type {
            // Infiere una sola vez el tipo de resultado del driver para todos los métodos CRUD.
            const Result = queryResultType(ConnectionType);
            return struct {
                const Self = @This();
                // El repositorio contiene el valor de conexión recibido; en el uso habitual,
                // guarda un puntero prestado cuya instancia pertenece al arranque de la
                // aplicación.
                connection: ConnectionType,

                pub fn select(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    entity_name: []const u8,
                    filters: []const rest.FieldValue,
                ) rest.RepositoryError!Result {
                    // La entrada de runtime elige entre ramas generadas a partir de los nombres
                    // permitidos en compilación. Los nombres desconocidos nunca llegan a SQL.
                    inline for (@typeInfo(@TypeOf(model_info)).@"struct".field_names) |name| {
                        if (std.mem.eql(u8, entity_name, name))
                            return self.selectEntity(allocator, name, filters);
                    }
                    // REST suele convertir este caso en 404 antes de entrar al repositorio;
                    // una llamada directa inválida recibe un error interno sin detalles
                    // sensibles.
                    return error.DatabaseError;
                }

                fn selectEntity(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    comptime entity_name: []const u8,
                    filters: []const rest.FieldValue,
                ) rest.RepositoryError!Result {
                    // Desde acá se conoce la entidad exacta en compilación, lo que permite
                    // los recorridos de campos por reflexión que siguen.
                    const entity = @field(model_info, entity_name);
                    if (hasUnknownOrDuplicate(entity, filters)) return error.DatabaseError;
                    // El texto SQL y el array de punteros son temporales para esta llamada.
                    var sql: std.ArrayList(u8) = .empty;
                    defer sql.deinit(allocator);
                    var parameters: std.ArrayList(?[]const u8) = .empty;
                    defer parameters.deinit(allocator);
                    // SELECT devuelve todas las columnas del schema en orden de declaración
                    // de la tabla; REST comprueba después la estructura del resultado.
                    sql.appendSlice(allocator, "SELECT * FROM ") catch return error.OutOfMemory;
                    appendIdentifier(allocator, &sql, entity_name) catch return error.OutOfMemory;
                    appendWhere(allocator, &sql, &parameters, entity, filters) catch return error.OutOfMemory;
                    // Los valores permanecen en `parameters`; queryParams los envía
                    // por separado del string SQL terminado.
                    return self.connection.queryParams(allocator, sql.items, parameters.items) catch |err|
                        return mapDatabaseError(self.connection, err);
                }

                pub fn insert(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    entity_name: []const u8,
                    values: []const rest.FieldValue,
                ) rest.RepositoryError!Result {
                    // Todos los métodos públicos repiten este despacho generado
                    // para no aceptar identificadores de tabla arbitrarios.
                    inline for (@typeInfo(@TypeOf(model_info)).@"struct".field_names) |name| {
                        if (std.mem.eql(u8, entity_name, name))
                            return self.insertEntity(allocator, name, values);
                    }
                    return error.DatabaseError;
                }

                fn insertEntity(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    comptime entity_name: []const u8,
                    values: []const rest.FieldValue,
                ) rest.RepositoryError!Result {
                    const entity = @field(model_info, entity_name);
                    // Un INSERT vacío tendría semántica ambigua o dependiente de defaults en
                    // esta API;
                    // los nombres desconocidos o duplicados violarían la seguridad de los
                    // identificadores.
                    if (values.len == 0 or hasUnknownOrDuplicate(entity, values)) return error.DatabaseError;
                    var sql: std.ArrayList(u8) = .empty;
                    defer sql.deinit(allocator);
                    var parameters: std.ArrayList(?[]const u8) = .empty;
                    defer parameters.deinit(allocator);
                    sql.appendSlice(allocator, "INSERT INTO ") catch return error.OutOfMemory;
                    appendIdentifier(allocator, &sql, entity_name) catch return error.OutOfMemory;
                    sql.appendSlice(allocator, " (") catch return error.OutOfMemory;
                    // Emite las columnas conocidas en orden de declaración de la entidad,
                    // aunque el objeto JSON las haya presentado en otro orden.
                    var emitted: usize = 0;
                    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
                        if (findValue(values, field_name)) |value| {
                            if (emitted != 0) sql.appendSlice(allocator, ", ") catch return error.OutOfMemory;
                            appendIdentifier(allocator, &sql, field_name) catch return error.OutOfMemory;
                            // El valor opcional se agrega sin cambios: libpq convierte null de
                            // Zig
                            // en un puntero de parámetro SQL NULL.
                            parameters.append(allocator, value.value) catch return error.OutOfMemory;
                            emitted += 1;
                        }
                    }
                    sql.appendSlice(allocator, ") VALUES (") catch return error.OutOfMemory;
                    // El orden de placeholders coincide exactamente con el vector
                    // de parámetros ya ordenado de forma canónica.
                    for (parameters.items, 0..) |_, index| {
                        if (index != 0) sql.appendSlice(allocator, ", ") catch return error.OutOfMemory;
                        appendParameter(allocator, &sql, index + 1) catch return error.OutOfMemory;
                    }
                    // RETURNING * hace que las respuestas a mutaciones usen la misma conversión
                    // de filas que SELECT y expongan a los clientes los valores normalizados
                    // por la base de datos.
                    sql.appendSlice(allocator, ") RETURNING *") catch return error.OutOfMemory;
                    return self.connection.queryParams(allocator, sql.items, parameters.items) catch |err|
                        return mapDatabaseError(self.connection, err);
                }

                pub fn update(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    entity_name: []const u8,
                    values: []const rest.FieldValue,
                    filters: []const rest.FieldValue,
                ) rest.RepositoryError!Result {
                    inline for (@typeInfo(@TypeOf(model_info)).@"struct".field_names) |name| {
                        if (std.mem.eql(u8, entity_name, name))
                            return self.updateEntity(allocator, name, values, filters);
                    }
                    return error.DatabaseError;
                }

                fn updateEntity(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    comptime entity_name: []const u8,
                    values: []const rest.FieldValue,
                    filters: []const rest.FieldValue,
                ) rest.RepositoryError!Result {
                    const entity = @field(model_info, entity_name);
                    // REST ya prohíbe actualizaciones vacías o sin filtros; se repiten
                    // esas invariantes para quienes usen el repositorio directamente.
                    if (values.len == 0 or filters.len == 0 or hasUnknownOrDuplicate(entity, values) or hasUnknownOrDuplicate(entity, filters))
                        return error.DatabaseError;
                    var sql: std.ArrayList(u8) = .empty;
                    defer sql.deinit(allocator);
                    var parameters: std.ArrayList(?[]const u8) = .empty;
                    defer parameters.deinit(allocator);
                    sql.appendSlice(allocator, "UPDATE ") catch return error.OutOfMemory;
                    appendIdentifier(allocator, &sql, entity_name) catch return error.OutOfMemory;
                    sql.appendSlice(allocator, " SET ") catch return error.OutOfMemory;
                    // Los valores de SET ocupan los primeros placeholders, en orden de campos
                    // de la entidad e independientemente del orden de miembros del JSON.
                    var emitted: usize = 0;
                    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
                        if (findValue(values, field_name)) |value| {
                            if (emitted != 0) sql.appendSlice(allocator, ", ") catch return error.OutOfMemory;
                            appendIdentifier(allocator, &sql, field_name) catch return error.OutOfMemory;
                            sql.appendSlice(allocator, " = ") catch return error.OutOfMemory;
                            parameters.append(allocator, value.value) catch return error.OutOfMemory;
                            appendParameter(allocator, &sql, parameters.items.len) catch return error.OutOfMemory;
                            emitted += 1;
                        }
                    }
                    // `appendWhere` continúa la numeración a partir de los parámetros de SET
                    // existentes y produce `$3`, `$4`, etc., según corresponda.
                    appendWhere(allocator, &sql, &parameters, entity, filters) catch return error.OutOfMemory;
                    sql.appendSlice(allocator, " RETURNING *") catch return error.OutOfMemory;
                    return self.connection.queryParams(allocator, sql.items, parameters.items) catch |err|
                        return mapDatabaseError(self.connection, err);
                }

                pub fn delete(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    entity_name: []const u8,
                    filters: []const rest.FieldValue,
                ) rest.RepositoryError!Result {
                    inline for (@typeInfo(@TypeOf(model_info)).@"struct".field_names) |name| {
                        if (std.mem.eql(u8, entity_name, name))
                            return self.deleteEntity(allocator, name, filters);
                    }
                    return error.DatabaseError;
                }

                fn deleteEntity(
                    self: *Self,
                    allocator: std.mem.Allocator,
                    comptime entity_name: []const u8,
                    filters: []const rest.FieldValue,
                ) rest.RepositoryError!Result {
                    const entity = @field(model_info, entity_name);
                    // En esta primera fase REST no hay una vía de DELETE sin filtros.
                    if (filters.len == 0 or hasUnknownOrDuplicate(entity, filters)) return error.DatabaseError;
                    var sql: std.ArrayList(u8) = .empty;
                    defer sql.deinit(allocator);
                    var parameters: std.ArrayList(?[]const u8) = .empty;
                    defer parameters.deinit(allocator);
                    sql.appendSlice(allocator, "DELETE FROM ") catch return error.OutOfMemory;
                    appendIdentifier(allocator, &sql, entity_name) catch return error.OutOfMemory;
                    appendWhere(allocator, &sql, &parameters, entity, filters) catch return error.OutOfMemory;
                    // Se devuelven las filas eliminadas para obtener una respuesta
                    // determinista;
                    // cero coincidencias sigue siendo un resultado vacío exitoso.
                    sql.appendSlice(allocator, " RETURNING *") catch return error.OutOfMemory;
                    return self.connection.queryParams(allocator, sql.items, parameters.items) catch |err|
                        return mapDatabaseError(self.connection, err);
                }
            };
        }
    };
}
