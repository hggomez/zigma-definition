//! Adaptador bloqueante mínimo de libpq para DDL y CRUD PostgreSQL parametrizado.

const std = @import("std");
// El paso translate-c de Zig genera `libpq` a partir de postgres_libpq.h.
// Mantener las declaraciones C detrás de este alias evita exponer los detalles
// de sus punteros al resto del framework.
const c = @import("libpq");

/// Los errores estables de Zig resumen las categorías de fallo del driver.
/// El mensaje detallado de PostgreSQL y SQLSTATE siguen disponibles en `Connection`,
/// sin formar parte del control de flujo de la aplicación ni de las respuestas HTTP.
pub const Error = error{
    OutOfMemory,
    NotConnected,
    AlreadyConnected,
    ConnectionFailed,
    TransactionAlreadyActive,
    SqlContainsNul,
    ConnectionStringContainsNul,
    PostgresError,
};

pub const QueryResult = struct {
    // Cada nombre de columna y celda copiada pertenece a esta arena privada.
    // Mover el resultado mueve el valor de la arena; sus bloques de memoria
    // siguen siendo válidos hasta `deinit`.
    arena: std.heap.ArenaAllocator,
    // El orden de columnas coincide con libpq/PQfname y se comprueba después
    // contra la SSOT, antes de generar la respuesta REST.
    columns: []const []const u8,
    // Slice externo = filas; slice interno = columnas; celda opcional = SQL NULL.
    // Los valores no-null son representaciones textuales de PostgreSQL copiadas a Zig.
    rows: []const []const ?[]const u8,

    pub fn deinit(self: *QueryResult) void {
        // Una sola operación libera todo el árbol del resultado.
        self.arena.deinit();
        // Marca como indefinido el valor movido o liberado en compilaciones con seguridad
        // activada para facilitar la detección de usos accidentales después de deinit.
        self.* = undefined;
    }
};

const ErrorPolicy = enum {
    // Las operaciones normales reemplazan el diagnóstico anterior con el propio.
    replace,
    // La limpieza mediante rollback conserva el error que lo originó.
    preserve,
};

/// Una única conexión bloqueante de libpq.
///
/// `lastError` pertenece a este valor y permanece válido hasta que otra
/// operación lo reemplace o se llame a `deinit`.
pub const Connection = struct {
    // Se usa para strings de conexión, SQL temporal compatible con C y copias
    // persistentes de diagnósticos. Los resultados pueden usar un allocator elegido al llamar.
    allocator: std.mem.Allocator,
    // `null` representa una conexión cerrada y evita inventar un handle C falso.
    // Solo este struct es responsable del PGconn y de llamar a PQfinish.
    handle: ?*c.PGconn = null,
    // Los punteros de error de libpq son prestados y pueden invalidarse en llamadas
    // posteriores; el adaptador guarda una copia con memoria propia.
    last_error: ?[]u8 = null,
    // Cuando PostgreSQL provee un SQLSTATE, siempre tiene cinco bytes ASCII.
    sql_state: [5]u8 = undefined,
    has_sql_state: bool = false,

    // El repositorio CRUD genérico puede descubrir el tipo concreto de resultado
    // de una conexión estructural. Este alias también facilita navegar el código.
    pub const Result = QueryResult;

    pub fn init(allocator: std.mem.Allocator) Connection {
        // Los demás campos usan los defaults declarados: inicializar
        // no reserva memoria ni abre un socket.
        return .{ .allocator = allocator };
    }

    pub fn connect(self: *Connection, conninfo: []const u8) Error!void {
        // Un valor Connection gestiona como máximo un PGconn. Reconectar exige un
        // deinit explícito para no reemplazar en silencio el recurso bajo su responsabilidad.
        if (self.handle != null) return error.AlreadyConnected;
        // Las APIs C usan NUL como terminador de string. Se rechazan los NUL internos
        // para que los bytes validados por Zig sean exactamente los que ve libpq.
        if (std.mem.indexOfScalar(u8, conninfo, 0) != null)
            return error.ConnectionStringContainsNul;

        // Cada operación nueva empieza sin diagnósticos anteriores.
        self.clearDiagnostic();
        // PQconnectdb espera `[*:0]const u8`. Los slices de Zig tienen longitud, pero
        // no garantizan un centinela: se crea una copia temporal terminada en centinela.
        const terminated = self.allocator.dupeSentinel(u8, conninfo, 0) catch
            return error.OutOfMemory;
        defer self.allocator.free(terminated);

        // libpq mantiene el PGconn devuelto hasta PQfinish, incluso
        // si falló el establecimiento de la conexión.
        const handle = c.PQconnectdb(terminated.ptr) orelse
            return error.OutOfMemory;
        if (c.PQstatus(handle) != c.CONNECTION_OK) {
            // Copia el diagnóstico prestado antes de destruir el handle de la conexión fallida.
            const remember_result = self.rememberConnectionError(handle, .replace);
            c.PQfinish(handle);
            remember_result catch return error.OutOfMemory;
            return error.ConnectionFailed;
        }

        // La responsabilidad sobre el recurso pasa a `self` solo después de confirmar el estado.
        self.handle = handle;
    }

    pub fn deinit(self: *Connection) void {
        // La captura del opcional llama a PQfinish solo si hay una conexión.
        if (self.handle) |handle| c.PQfinish(handle);
        // Restablecer el handle hace inocuas las llamadas repetidas a deinit respecto de C.
        self.handle = null;
        // El mensaje guardado es la única otra reserva de memoria propia de Connection.
        self.clearLastError();
    }

    /// Inicia una transacción solo cuando libpq informa que la conexión está inactiva.
    pub fn begin(self: *Connection) Error!void {
        // La validación centralizada del handle también detecta una conexión
        // que se perdió después de haberse establecido correctamente.
        const handle = try self.connectedHandle();
        // `executeSchema` se compromete a gestionar su propia transacción. Rechazar
        // estados no inactivos evita confirmar o revertir una transacción de quien llama.
        if (c.PQtransactionStatus(handle) != c.PQTRANS_IDLE)
            return error.TransactionAlreadyActive;

        // El resultado de BEGIN debe reemplazar los diagnósticos de operaciones anteriores.
        self.clearLastError();
        // Un literal de string ya termina en centinela, como requiere el helper.
        try self.execTerminated(handle, "BEGIN", .replace);
    }

    /// Ejecuta SQL confiable. `PQexec` admite múltiples sentencias.
    pub fn exec(self: *Connection, sql: []const u8) Error!void {
        const handle = try self.connectedHandle();
        // Como con conninfo, se rechazan diferencias por truncamiento en la interfaz con C.
        if (std.mem.indexOfScalar(u8, sql, 0) != null)
            return error.SqlContainsNul;

        self.clearDiagnostic();
        // PQexec admite múltiples sentencias confiables, pero requiere un string C:
        // se reserva y luego se libera una copia temporal con terminador.
        const terminated = self.allocator.dupeSentinel(u8, sql, 0) catch
            return error.OutOfMemory;
        defer self.allocator.free(terminated);
        try self.execTerminated(handle, terminated, .replace);
    }

    /// Ejecuta una sentencia con parámetros textuales de libpq y devuelve un resultado
    /// tabular con memoria propia. Los parámetros `null` se convierten en SQL NULL;
    /// cada valor no-null se envía por separado del string SQL.
    pub fn queryParams(
        self: *Connection,
        allocator: std.mem.Allocator,
        sql: []const u8,
        parameters: []const ?[]const u8,
    ) Error!QueryResult {
        // `queryParams` es la única primitiva de transporte CRUD: la estructura SQL
        // es un string y cada valor no confiable es un elemento separado.
        const handle = try self.connectedHandle();
        if (std.mem.indexOfScalar(u8, sql, 0) != null)
            return error.SqlContainsNul;

        self.clearDiagnostic();
        // Las conversiones a strings C de esta llamada tienen la misma duración;
        // una arena temporal evita gestionar N+1 liberaciones por separado.
        var temporary = std.heap.ArenaAllocator.init(self.allocator);
        defer temporary.deinit();
        const temporary_allocator = temporary.allocator();
        // SQL y cada parámetro textual no-null deben terminar en NUL para cumplir
        // el contrato de formato textual predeterminado de PQexecParams.
        const terminated_sql = temporary_allocator.dupeSentinel(u8, sql, 0) catch
            return error.OutOfMemory;
        // `[ *c ]const u8` corresponde al `const char *` de C, que admite null.
        // Un puntero null en este array indica a libpq que envíe SQL NULL.
        const parameter_values = temporary_allocator.alloc([*c]const u8, parameters.len) catch
            return error.OutOfMemory;
        for (parameters, 0..) |parameter, index| {
            if (parameter) |value| {
                // Los parámetros textuales también usan strings C: un NUL interno
                // produciría un truncamiento ambiguo y se rechaza.
                if (std.mem.indexOfScalar(u8, value, 0) != null)
                    return error.SqlContainsNul;
                const terminated = temporary_allocator.dupeSentinel(u8, value, 0) catch
                    return error.OutOfMemory;
                parameter_values[index] = terminated.ptr;
            } else {
                // No se pasan los bytes "NULL": el protocolo representa un
                // parámetro SQL NULL mediante un puntero null.
                parameter_values[index] = null;
            }
        }

        // Los tipos, longitudes y formatos de parámetros son null porque PostgreSQL
        // puede inferir los tipos del contexto SQL y todos los parámetros son textuales.
        // Un formato de resultado 0 solicita celdas de texto legible.
        const result = c.PQexecParams(
            handle,
            terminated_sql.ptr,
            @intCast(parameters.len),
            null,
            if (parameter_values.len == 0) null else parameter_values.ptr,
            null,
            null,
            0,
        ) orelse {
            // Si PGresult es null, solo la conexión puede aportar diagnósticos.
            self.rememberConnectionError(handle, .replace) catch
                return error.OutOfMemory;
            return error.PostgresError;
        };
        // Cada PGresult no-null debe tener su PQclear, sin importar su estado
        // ni si falla la copia posterior del resultado.
        defer c.PQclear(result);

        // Todas las sentencias CRUD usan RETURNING o SELECT: un resultado exitoso
        // debe contener tuplas, no solo indicar que terminó el comando.
        if (c.PQresultStatus(result) != c.PGRES_TUPLES_OK) {
            self.rememberResultError(handle, result, .replace) catch
                return error.OutOfMemory;
            return error.PostgresError;
        }
        // Los punteros a celdas de libpq duran hasta PQclear; se realiza una copia
        // profunda antes de que corra la limpieza diferida.
        return copyQueryResult(allocator, result);
    }

    pub fn commit(self: *Connection) Error!void {
        // COMMIT usa la misma vía de ejecución comprobada que BEGIN y ROLLBACK.
        const handle = try self.connectedHandle();
        try self.execTerminated(handle, "COMMIT", .replace);
    }

    /// Revierte la transacción conservando el diagnóstico de la operación que
    /// provocó el rollback. El error del rollback se guarda solo si no hay
    /// un diagnóstico previo de PostgreSQL.
    pub fn rollback(self: *Connection) Error!void {
        const handle = try self.connectedHandle();
        try self.execTerminated(handle, "ROLLBACK", .preserve);
    }

    pub fn lastError(self: *const Connection) ?[]const u8 {
        // Devuelve una vista prestada. Connection conserva la memoria hasta la
        // próxima operación que cambie el diagnóstico o hasta deinit.
        return self.last_error;
    }

    pub fn lastSqlState(self: *const Connection) ?[]const u8 {
        // No expone el almacenamiento sin inicializar salvo que se haya copiado un código de
        // cinco bytes.
        if (!self.has_sql_state) return null;
        return self.sql_state[0..];
    }

    fn connectedHandle(self: *Connection) Error!*c.PGconn {
        // Primero extrae el handle del estado opcional que lo contiene.
        const handle = self.handle orelse return error.NotConnected;
        // Un PGconn puede fallar después de connect; se comprueba en cada operación pública.
        if (c.PQstatus(handle) != c.CONNECTION_OK) {
            self.rememberConnectionError(handle, .replace) catch
                return error.OutOfMemory;
            return error.ConnectionFailed;
        }
        return handle;
    }

    fn execTerminated(
        self: *Connection,
        handle: *c.PGconn,
        sql: [:0]const u8,
        error_policy: ErrorPolicy,
    ) Error!void {
        // Este helper acepta un slice con centinela para impedir que se pase
        // accidentalmente a PQexec un string incompatible con C.
        const result = c.PQexec(handle, sql.ptr) orelse {
            self.rememberConnectionError(handle, error_policy) catch
                return error.OutOfMemory;
            return error.PostgresError;
        };
        defer c.PQclear(result);

        // Los comandos DDL y de transacción deben informar PGRES_COMMAND_OK. Los
        // resultados de tuplas corresponden a `queryParams`, que gestiona su memoria de otra forma.
        if (c.PQresultStatus(result) != c.PGRES_COMMAND_OK) {
            self.rememberResultError(handle, result, error_policy) catch
                return error.OutOfMemory;
            return error.PostgresError;
        }
    }

    fn rememberResultError(
        self: *Connection,
        handle: *c.PGconn,
        result: *c.PGresult,
        policy: ErrorPolicy,
    ) std.mem.Allocator.Error!void {
        // Se prefiere el mensaje del resultado porque describe esta sentencia
        // exacta; el mensaje de la conexión se usa como alternativa.
        const result_message = spanCString(c.PQresultErrorMessage(result));
        // Durante rollback se conserva el SQLSTATE anterior, igual que el error
        // legible. En los demás casos se copian exactamente cinco bytes.
        if (policy == .replace or !self.has_sql_state) {
            const state = spanCString(c.PQresultErrorField(result, c.PG_DIAG_SQLSTATE));
            if (state.len == self.sql_state.len) {
                @memcpy(&self.sql_state, state);
                self.has_sql_state = true;
            }
        }
        if (result_message.len != 0)
            return self.rememberError(result_message, policy);
        return self.rememberConnectionError(handle, policy);
    }

    fn rememberConnectionError(
        self: *Connection,
        handle: *c.PGconn,
        policy: ErrorPolicy,
    ) std.mem.Allocator.Error!void {
        // libpq devuelve un mensaje prestado terminado en NUL incluso ante fallos de
        // conexión. Un mensaje vacío, poco frecuente, se reemplaza por uno útil.
        const message = spanCString(c.PQerrorMessage(handle));
        return self.rememberError(
            if (message.len == 0) "unknown libpq error" else message,
            policy,
        );
    }

    fn rememberError(
        self: *Connection,
        message: []const u8,
        policy: ErrorPolicy,
    ) std.mem.Allocator.Error!void {
        // La limpieza no debe borrar el diagnóstico principal.
        if (policy == .preserve and self.last_error != null) return;
        // Primero copia y después libera el mensaje anterior: si falla la reserva
        // de memoria, el diagnóstico previo queda intacto.
        const copy = try self.allocator.dupe(u8, message);
        self.clearLastError();
        self.last_error = copy;
    }

    fn clearLastError(self: *Connection) void {
        // La captura del opcional libera solo el almacenamiento propio ya inicializado.
        if (self.last_error) |message| self.allocator.free(message);
        self.last_error = null;
    }

    fn clearDiagnostic(self: *Connection) void {
        // El texto legible y SQLSTATE describen una misma operación y se restablecen juntos.
        self.clearLastError();
        self.has_sql_state = false;
    }
};

fn copyQueryResult(allocator: std.mem.Allocator, result: *c.PGresult) Error!QueryResult {
    // Una arena dedicada permite que el resultado público contenga una tabla con
    // anidamiento arbitrario y la libere con un solo deinit. `errdefer` cubre la construcción parcial.
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    // libpq usa enteros C con signo; las dimensiones de un resultado exitoso
    // no son negativas y `@intCast` las convierte en índices de slices Zig.
    const column_count: usize = @intCast(c.PQnfields(result));
    const row_count: usize = @intCast(c.PQntuples(result));

    // Copia los nombres de columnas porque PQfname apunta al almacenamiento de PGresult.
    const columns = owned.alloc([]const u8, column_count) catch return error.OutOfMemory;
    for (columns, 0..) |*column, index| {
        const name = spanCString(c.PQfname(result, @intCast(index)));
        column.* = owned.dupe(u8, name) catch return error.OutOfMemory;
    }

    // Reserva el array externo de filas y luego un slice de valores opcionales por fila.
    const rows = owned.alloc([]const ?[]const u8, row_count) catch return error.OutOfMemory;
    for (rows, 0..) |*row, row_index| {
        const values = owned.alloc(?[]const u8, column_count) catch return error.OutOfMemory;
        for (values, 0..) |*value, column_index| {
            // Se debe comprobar PQgetisnull antes de PQgetvalue: un string vacío
            // y SQL NULL son valores distintos de la base de datos.
            if (c.PQgetisnull(result, @intCast(row_index), @intCast(column_index)) != 0) {
                value.* = null;
            } else {
                // La copia basada en longitud evita depender del centinela C
                // y conserva correctamente los valores de texto vacíos.
                const pointer = c.PQgetvalue(result, @intCast(row_index), @intCast(column_index));
                const length: usize = @intCast(c.PQgetlength(result, @intCast(row_index), @intCast(column_index)));
                value.* = owned.dupe(u8, pointer[0..length]) catch return error.OutOfMemory;
            }
        }
        row.* = values;
    }
    // Mover la arena a QueryResult transfiere la responsabilidad de liberarla a quien llama.
    return .{ .arena = arena, .columns = columns, .rows = rows };
}

fn spanCString(pointer: [*c]const u8) []const u8 {
    // Los punteros C admiten null aunque su sintaxis Zig no sea opcional.
    if (pointer == null) return "";
    // Después de comprobar null, reinterpreta el puntero como terminado en centinela
    // y deja que `std.mem.span` determine su longitud sin copiarlo.
    const sentinel_pointer: [*:0]const u8 = @ptrCast(pointer);
    return std.mem.span(sentinel_pointer);
}
