//! Controladores CRUD REST derivados de entidades Zigma en compilación.
//!
//! Este módulo se ocupa de routing, validación de solicitudes, codecs de dominio
//! y JSON. No conoce sockets ni PostgreSQL; `Api.handle` comprueba
//! los repositorios de forma estructural.

const std = @import("std");

// Los codecs exponen un conjunto acotado de errores. El valor es inválido para
// su dominio o la normalización no pudo reservar memoria para la solicitud.
pub const CodecError = error{ InvalidValue, OutOfMemory };

/// Conecta un tipo de dominio Zigma entre valores HTTP/JSON y el protocolo
/// textual de PostgreSQL. El motor REST gestiona null; los codecs solo reciben valores no-null.
pub const Codec = struct {
    queryToPostgres: *const fn (std.mem.Allocator, []const u8) CodecError![]const u8,
    jsonToPostgres: *const fn (std.mem.Allocator, std.json.Value) CodecError![]const u8,
    postgresToJson: *const fn (std.mem.Allocator, []const u8) CodecError!std.json.Value,
};

fn textFromQuery(allocator: std.mem.Allocator, value: []const u8) CodecError![]const u8 {
    // Copia el valor a memoria propia para el resto de la solicitud, sin depender
    // de la duración del buffer de query del adaptador HTTP.
    return allocator.dupe(u8, value) catch error.OutOfMemory;
}

fn textFromJson(allocator: std.mem.Allocator, value: std.json.Value) CodecError![]const u8 {
    // No convierte números o booleanos JSON a strings en silencio:
    // el tipo JSON enviado por el cliente forma parte del contrato REST.
    if (value != .string) return error.InvalidValue;
    return allocator.dupe(u8, value.string) catch error.OutOfMemory;
}

fn textToJson(_: std.mem.Allocator, value: []const u8) CodecError!std.json.Value {
    // El resultado del repositorio sigue vigente durante la serialización:
    // el nodo JSON puede tomar prestados sus bytes con seguridad.
    return .{ .string = value };
}

fn integerFromQuery(allocator: std.mem.Allocator, value: []const u8) CodecError![]const u8 {
    // Parsear y volver a formatear valida la entrada y produce una
    // representación canónica en base 10 para el parámetro PostgreSQL.
    const parsed = std.fmt.parseInt(i64, value, 10) catch return error.InvalidValue;
    return std.fmt.allocPrint(allocator, "{d}", .{parsed}) catch error.OutOfMemory;
}

fn integerFromJson(allocator: std.mem.Allocator, value: std.json.Value) CodecError![]const u8 {
    // std.json distingue enteros de flotantes: se rechaza 1.5 en lugar de
    // truncarlo o dejar que PostgreSQL lo acepte mediante una conversión implícita.
    if (value != .integer) return error.InvalidValue;
    return std.fmt.allocPrint(allocator, "{d}", .{value.integer}) catch error.OutOfMemory;
}

fn integerToJson(_: std.mem.Allocator, value: []const u8) CodecError!std.json.Value {
    // Un valor de base no entero indica que se rompió el contrato entre repositorio
    // y dominio; terminará como un error de servidor sin detalles internos.
    return .{ .integer = std.fmt.parseInt(i64, value, 10) catch return error.InvalidValue };
}

fn booleanFromQuery(allocator: std.mem.Allocator, value: []const u8) CodecError![]const u8 {
    // Mantiene estricta la representación pública, sin aceptar los múltiples
    // aliases booleanos de PostgreSQL (t/f, yes/no, 1/0).
    if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false"))
        return error.InvalidValue;
    return allocator.dupe(u8, value) catch error.OutOfMemory;
}

fn booleanFromJson(allocator: std.mem.Allocator, value: std.json.Value) CodecError![]const u8 {
    if (value != .bool) return error.InvalidValue;
    return allocator.dupe(u8, if (value.bool) "true" else "false") catch error.OutOfMemory;
}

fn booleanToJson(_: std.mem.Allocator, value: []const u8) CodecError!std.json.Value {
    // libpq suele devolver t/f; aceptar también la forma larga facilita
    // el uso de repositorios falsos y adaptadores alternativos.
    if (std.mem.eql(u8, value, "t") or std.mem.eql(u8, value, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, value, "f") or std.mem.eql(u8, value, "false")) return .{ .bool = false };
    return error.InvalidValue;
}

pub const text_codec = Codec{
    .queryToPostgres = textFromQuery,
    .jsonToPostgres = textFromJson,
    .postgresToJson = textToJson,
};

pub const integer_codec = Codec{
    .queryToPostgres = integerFromQuery,
    .jsonToPostgres = integerFromJson,
    .postgresToJson = integerToJson,
};

pub const boolean_codec = Codec{
    .queryToPostgres = booleanFromQuery,
    .jsonToPostgres = booleanFromJson,
    .postgresToJson = booleanToJson,
};

/// Codecs de los dominios incorporados en Zigma. Este struct anónimo
/// se puede extender con codecs de la aplicación mediante `zigma.merge`.
pub const common_codecs = .{
    .text = text_codec,
    .integer = integer_codec,
    .boolean = boolean_codec,
};

fn isCodec(comptime T: type) bool {
    // La igualdad exacta es útil acá: cada codec tiene un contrato estable de
    // tipo ABI, sin confiar en que un valor con nombre parecido funcione después.
    return T == Codec;
}

pub fn defineCodecs(comptime type_defs: anytype, comptime codecs: anytype) @TypeOf(codecs) {
    // Ambos bucles corren en compilación. El primero detecta nombres erróneos,
    // entradas adicionales y firmas inválidas; el segundo comprueba la cobertura de dominios.
    inline for (@typeInfo(@TypeOf(codecs)).@"struct".field_names) |name| {
        if (!@hasField(@TypeOf(type_defs), name))
            @compileError("REST codec '" ++ name ++ "': unknown domain type");
        if (!isCodec(@TypeOf(@field(codecs, name))))
            @compileError("REST codec '" ++ name ++ "': must be a zigma_rest.Codec");
    }
    inline for (@typeInfo(@TypeOf(type_defs)).@"struct".field_names) |name| {
        if (!@hasField(@TypeOf(codecs), name))
            @compileError("domain type '" ++ name ++ "': missing REST codec");
    }
    return codecs;
}

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

/// Descripción estable, visible para el cliente, de un estado de negocio rechazado.
/// Los validadores son código de aplicación; el motor REST construye la respuesta HTTP de
/// error.
pub const BusinessRuleViolation = struct {
    code: []const u8,
    message: []const u8,
};

/// `InvalidState` indica que el validador no pudo interpretar una fila completa
/// supuestamente normalizada. Es un error interno de contrato, no una infracción
/// del cliente: se devuelve como HTTP 500 sin exponer detalles internos.
pub const BusinessValidationError = error{InvalidState};

/// La validación de entidad recibe una fila completa con la misma forma normalizada
/// de texto/null que usan los repositorios. Así no depende de JSON, HTTP
/// ni de un driver PostgreSQL concreto.
pub const BusinessValidator = struct {
    validate: *const fn ([]const FieldValue) BusinessValidationError!?BusinessRuleViolation,
};

/// Valida un registro opcional comptime por nombre de entidad. Las entidades
/// omitidas no tienen validación de negocio ni requieren una consulta PUT adicional.
pub fn defineBusinessValidators(
    comptime Model: type,
    comptime validators: anytype,
) @TypeOf(validators) {
    const model_info = Model.info;
    inline for (@typeInfo(@TypeOf(validators)).@"struct".field_names) |entity_name| {
        if (!@hasField(@TypeOf(model_info), entity_name))
            @compileError("REST business validator '" ++ entity_name ++ "': unknown entity");
        if (@TypeOf(@field(validators, entity_name)) != BusinessValidator)
            @compileError("REST business validator '" ++ entity_name ++ "': must be a zigma_rest.BusinessValidator");
    }
    return validators;
}

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

// Los filtros de query no pueden expresar SQL NULL en esta primera versión REST.
const RawFilter = struct { name: []const u8, value: []const u8 };

fn routeList(comptime entity_defs: anytype) [@typeInfo(@TypeOf(entity_defs)).@"struct".field_names.len]Route {
    // Los nombres de entidades y el tamaño del array se conocen en compilación;
    // no hace falta registrar rutas al arrancar ni usar reflexión en runtime.
    const names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;
    var result: [names.len]Route = undefined;
    inline for (names, 0..) |name, index| result[index] = .{ .path = "/api/" ++ name };
    return result;
}

fn isPrimaryKey(comptime entity: anytype, comptime field_name: []const u8) bool {
    for (entity.pk) |pk_name|
        if (std.mem.eql(u8, pk_name, field_name)) return true;
    return false;
}

fn decodeHex(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn percentDecode(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    // La decodificación crea bytes propios de la solicitud. `errdefer` también
    // libera un valor parcialmente construido si encuentra un escape mal formado.
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < encoded.len) {
        if (encoded[index] == '%') {
            // Los escapes porcentuales son exactamente `%` seguido de dos dígitos hexadecimales.
            if (index + 2 >= encoded.len) return error.InvalidEncoding;
            const high = decodeHex(encoded[index + 1]) orelse return error.InvalidEncoding;
            const low = decodeHex(encoded[index + 2]) orelse return error.InvalidEncoding;
            try output.append(allocator, high * 16 + low);
            index += 3;
        } else {
            // Las queries con formato de formulario HTML codifican los espacios como `+`;
            // un signo más literal es `%2B` y por eso pasa por la rama anterior.
            try output.append(allocator, if (encoded[index] == '+') ' ' else encoded[index]);
            index += 1;
        }
    }
    // Los strings JSON y el contrato textual PostgreSQL de este framework usan UTF-8.
    if (!std.unicode.utf8ValidateSlice(output.items)) return error.InvalidEncoding;
    return output.toOwnedSlice(allocator);
}

fn parseFilters(allocator: std.mem.Allocator, query: []const u8) ![]RawFilter {
    // Conserva el orden de la URL solo al parsear y detectar duplicados.
    // Una etapa posterior ordena los filtros según la declaración de la entidad.
    var filters: std.ArrayList(RawFilter) = .empty;
    errdefer filters.deinit(allocator);
    if (query.len == 0) return filters.toOwnedSlice(allocator);

    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) return error.InvalidQuery;
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidQuery;
        const name = try percentDecode(allocator, pair[0..equals]);
        const value = try percentDecode(allocator, pair[equals + 1 ..]);
        // Rechaza duplicados para evitar una convención inesperada de primero o último
        // que gana, que podría diferir entre clientes y proxies.
        for (filters.items) |existing|
            if (std.mem.eql(u8, existing.name, name)) return error.DuplicateFilter;
        try filters.append(allocator, .{ .name = name, .value = value });
    }
    return filters.toOwnedSlice(allocator);
}

fn contentTypeIsJson(value: ?[]const u8) bool {
    // Admite parámetros como `charset=utf-8` y compara el tipo de contenido
    // sin distinguir mayúsculas, tal como exige HTTP.
    const content_type = value orelse return false;
    const end = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, content_type[0..end], " \t"), "application/json");
}

fn jsonResponse(allocator: std.mem.Allocator, status: u16, value: anytype) !Response {
    // El writer con allocator produce un cuerpo contiguo y transfiere su memoria
    // a Response. Después se pueden descartar los datos temporales de la solicitud.
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var stringify: std.json.Stringify = .{ .writer = &output.writer };
    try stringify.write(value);
    return .{ .status = status, .body = try output.toOwnedSlice() };
}

fn errorResponse(allocator: std.mem.Allocator, status: u16, code: []const u8, message: []const u8) !Response {
    // Un único constructor mantiene uniforme la estructura de errores visible para el cliente.
    return jsonResponse(allocator, status, .{ .@"error" = .{ .code = code, .message = message } });
}

fn repositoryErrorResponse(allocator: std.mem.Allocator, err: anyerror) !Response {
    // Solo las categorías estables cruzan la interfaz HTTP. Los diagnósticos
    // PostgreSQL quedan privados, sin exponer detalles del schema ni de la conexión.
    return switch (err) {
        error.Conflict => errorResponse(allocator, 409, "constraint_conflict", "PostgreSQL constraint rejected the operation"),
        error.Unavailable => errorResponse(allocator, 503, "database_unavailable", "Database is unavailable"),
        error.OutOfMemory => error.OutOfMemory,
        else => errorResponse(allocator, 500, "database_error", "Database operation failed"),
    };
}

fn rawFilter(raw: []const RawFilter, name: []const u8) ?[]const u8 {
    // `name` proviene de los metadatos comptime de la entidad. El texto de la URL
    // solo se compara con él; una entrada arbitraria nunca se convierte en identificador SQL.
    for (raw) |filter| if (std.mem.eql(u8, filter.name, name)) return filter.value;
    return null;
}

fn validateFilterNames(comptime entity: anytype, raw: []const RawFilter) bool {
    // Las claves recibidas en runtime se comprueban contra la lista completa permitida en
    // comptime.
    for (raw) |filter| {
        var found = false;
        inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
            if (std.mem.eql(u8, filter.name, field_name)) {
                found = true;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn buildFilters(
    allocator: std.mem.Allocator,
    comptime entity: anytype,
    comptime codecs: anytype,
    raw: []const RawFilter,
) ![]FieldValue {
    // Recorre los metadatos de la entidad en vez del orden de la URL: `$1`, `$2`, ...
    // son estables para un conjunto de filtros y los identificadores provienen de metadatos
    // confiables.
    var result: std.ArrayList(FieldValue) = .empty;
    errdefer result.deinit(allocator);
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
        if (rawFilter(raw, field_name)) |raw_value| {
            const domain_type = @field(entity.fields, field_name).type;
            // El codec de dominio del campo valida y normaliza solo el valor;
            // la parametrización SQL posterior impide que se convierta en código SQL.
            const value = @field(codecs, domain_type).queryToPostgres(allocator, raw_value) catch
                return error.InvalidFilterValue;
            try result.append(allocator, .{ .name = field_name, .value = value });
        }
    }
    return result.toOwnedSlice(allocator);
}

fn objectHasUnknownField(comptime entity: anytype, object: std.json.ObjectMap) bool {
    // Las claves del objeto JSON son entrada de runtime y deben pertenecer
    // a la entidad antes de construir una operación del repositorio.
    for (object.keys()) |name| {
        var found = false;
        inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
            if (std.mem.eql(u8, name, field_name)) {
                found = true;
            }
        }
        if (!found) return true;
    }
    return false;
}

fn buildInsertValues(
    allocator: std.mem.Allocator,
    comptime entity: anytype,
    comptime codecs: anytype,
    object: std.json.ObjectMap,
) ![]FieldValue {
    // Los valores de INSERT siguen el orden de declaración. Los campos nullable
    // omitidos se completan con SQL NULL; se debe aportar cada campo efectivamente NOT NULL.
    var result: std.ArrayList(FieldValue) = .empty;
    errdefer result.deinit(allocator);
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
        const field_value = object.get(field_name);
        if (field_value == null) {
            if (!@field(entity.fields, field_name).nullable) return error.MissingRequiredField;
            try result.append(allocator, .{ .name = field_name, .value = null });
        } else if (field_value.? == .null) {
            if (!@field(entity.fields, field_name).nullable) return error.NullNotAllowed;
            try result.append(allocator, .{ .name = field_name, .value = null });
        } else {
            const domain_type = @field(entity.fields, field_name).type;
            const encoded = @field(codecs, domain_type).jsonToPostgres(allocator, field_value.?) catch
                return error.InvalidBodyValue;
            try result.append(allocator, .{ .name = field_name, .value = encoded });
        }
    }
    return result.toOwnedSlice(allocator);
}

fn buildUpdateValues(
    allocator: std.mem.Allocator,
    comptime entity: anytype,
    comptime codecs: anytype,
    object: std.json.ObjectMap,
) ![]FieldValue {
    // PUT es parcial: solo las claves del cuerpo generan asignaciones. Las PK
    // son inmutables para que este endpoint no traslade relaciones en silencio.
    var result: std.ArrayList(FieldValue) = .empty;
    errdefer result.deinit(allocator);
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
        if (object.get(field_name)) |field_value| {
            if (isPrimaryKey(entity, field_name)) return error.PrimaryKeyUpdate;
            if (field_value == .null) {
                if (!@field(entity.fields, field_name).nullable) return error.NullNotAllowed;
                try result.append(allocator, .{ .name = field_name, .value = null });
            } else {
                const domain_type = @field(entity.fields, field_name).type;
                const encoded = @field(codecs, domain_type).jsonToPostgres(allocator, field_value) catch
                    return error.InvalidBodyValue;
                try result.append(allocator, .{ .name = field_name, .value = encoded });
            }
        }
    }
    // `{}` produciría SQL inválido y casi con seguridad es un error del cliente:
    // se rechaza antes de llegar al repositorio.
    if (result.items.len == 0) return error.EmptyUpdate;
    return result.toOwnedSlice(allocator);
}

fn renderResult(
    response_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    comptime entity: anytype,
    comptime codecs: anytype,
    result: anytype,
    status: u16,
    single: bool,
) !Response {
    // El contrato del repositorio exige todas las columnas de la entidad en orden
    // de declaración. Se comprueba antes de indexar celdas o aplicar codecs de dominio.
    const field_names = @typeInfo(@TypeOf(entity.fields)).@"struct".field_names;
    if (result.columns.len != field_names.len) return error.InvalidRepositoryResult;
    inline for (field_names, 0..) |field_name, index| {
        if (!std.mem.eql(u8, result.columns[index], field_name)) return error.InvalidRepositoryResult;
    }
    // POST promete exactamente la fila producida por INSERT ... RETURNING *.
    if (single and result.rows.len != 1) return error.InvalidRepositoryResult;

    var output: std.Io.Writer.Allocating = .init(response_allocator);
    errdefer output.deinit();
    var stringify: std.json.Stringify = .{ .writer = &output.writer };
    if (!single) try stringify.beginArray();
    for (result.rows) |row| {
        if (row.len != field_names.len) return error.InvalidRepositoryResult;
        try stringify.beginObject();
        inline for (field_names, 0..) |field_name, index| {
            try stringify.objectField(field_name);
            if (row[index]) |database_value| {
                // El texto no-null pasa por el codec del campo; SQL NULL se
                // representa directamente como JSON null sin pasar por el codec.
                const domain_type = @field(entity.fields, field_name).type;
                const json_value = @field(codecs, domain_type).postgresToJson(scratch_allocator, database_value) catch
                    return error.InvalidRepositoryResult;
                try stringify.write(json_value);
            } else {
                try stringify.write(null);
            }
        }
        try stringify.endObject();
    }
    if (!single) try stringify.endArray();
    return .{ .status = status, .body = try output.toOwnedSlice() };
}

fn parseJsonObject(allocator: std.mem.Allocator, body: []const u8) !std.json.Parsed(std.json.Value) {
    // Los nodos parseados viven en la arena de la solicitud. Solo se acepta un objeto;
    // los arrays para operaciones masivas quedan fuera de la fase 3.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidJson;
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;
    return parsed;
}

fn requestValidationResponse(allocator: std.mem.Allocator, err: anyerror) !Response {
    // Varios errores internos de validación se reducen a un único contrato 400 seguro;
    // solo el tamaño del cuerpo y el tipo de contenido reciben estados distintos.
    return switch (err) {
        error.BodyTooLarge => errorResponse(allocator, 413, "body_too_large", "Request body exceeds the configured limit"),
        error.UnsupportedMediaType => errorResponse(allocator, 415, "unsupported_media_type", "Expected application/json"),
        else => errorResponse(allocator, 400, "invalid_request", "Request fields or values are invalid"),
    };
}

fn businessViolationResponse(
    allocator: std.mem.Allocator,
    violation: BusinessRuleViolation,
) !Response {
    return errorResponse(allocator, 422, violation.code, violation.message);
}

fn fieldValue(values: []const FieldValue, name: []const u8) ?FieldValue {
    for (values) |value| {
        if (std.mem.eql(u8, value.name, name)) return value;
    }
    return null;
}

fn resultHasEntityShape(comptime entity: anytype, result: anytype) bool {
    const field_names = @typeInfo(@TypeOf(entity.fields)).@"struct".field_names;
    if (result.columns.len != field_names.len) return false;
    inline for (field_names, 0..) |field_name, index| {
        if (!std.mem.eql(u8, result.columns[index], field_name)) return false;
    }
    for (result.rows) |row| {
        if (row.len != field_names.len) return false;
    }
    return true;
}

/// Un cuerpo PUT es solo un patch: se valida cada estado resultante de aplicarlo
/// a las filas seleccionadas por los filtros. Los arrays combinados toman prestadas
/// ambas entradas y duran solo durante la llamada síncrona al validador.
fn validateUpdatedRows(
    comptime entity: anytype,
    current: anytype,
    updates: []const FieldValue,
    validator: BusinessValidator,
) !?BusinessRuleViolation {
    if (!resultHasEntityShape(entity, current)) return error.InvalidRepositoryResult;
    const field_names = @typeInfo(@TypeOf(entity.fields)).@"struct".field_names;
    for (current.rows) |row| {
        var merged: [field_names.len]FieldValue = undefined;
        inline for (field_names, 0..) |field_name, index| {
            merged[index] = fieldValue(updates, field_name) orelse .{
                .name = field_name,
                .value = row[index],
            };
        }
        if (try validator.validate(&merged)) |violation| return violation;
    }
    return null;
}

/// `Api` es una fábrica de tipos comptime: no crea ahora un objeto API, sino el
/// *tipo* concreto que después guardará configuración y atenderá solicitudes.
/// Es similar a especializar una plantilla de clase C++, salvo que Zig acepta
/// el modelo normalizado y los codecs como entradas comptime.
pub fn Api(
    // El namespace Model contiene los metadatos ya normalizados y validados.
    comptime Model: type,
    // Los codecs también son datos de compilación: se comprueba que cada campo
    // expuesto tenga conversiones HTTP/JSON/PostgreSQL antes de arrancar el servidor.
    comptime codecs: anytype,
) type {
    return ApiWithBusinessValidators(Model, codecs, .{});
}

/// Variante de `Api` con validación opcional de negocio por entidad. El registro
/// es información comptime: cada handler generado incluye una llamada directa
/// al validador o no tiene ninguna rama de validación.
pub fn ApiWithBusinessValidators(
    comptime Model: type,
    comptime codecs: anytype,
    comptime validators: anytype,
) type { // Devolver `type` es lo que convierte esta función en una fábrica de tipos.
    // System ya comprobó las entidades y resolvió la nulabilidad efectiva.
    // REST consume esos mismos metadatos sin reinterpretar el contrato.
    const model_info = Model.info;
    const checked_validators = defineBusinessValidators(Model, validators);

    // `@TypeOf(model_info)` obtiene el tipo struct anónimo de la colección de entidades;
    // `@typeInfo(...).@"struct".field_names` expone sus nombres. `inline for` despliega
    // el bucle durante la compilación y produce una rama de validación por entidad,
    // en lugar de un bucle de reflexión en runtime.
    inline for (@typeInfo(@TypeOf(model_info)).@"struct".field_names) |entity_name| {
        // `entity_name` es un string comptime: `@field` puede seleccionar la entidad
        // por nombre en un struct anónimo, aunque la sintaxis normal `.field`
        // no se pueda escribir cuando el nombre proviene de un bucle.
        const entity = @field(model_info, entity_name);

        // Repite la misma reflexión en compilación sobre los campos de esta entidad.
        inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
            // Las definiciones de campos guardan su tipo de dominio como un nombre,
            // por ejemplo `"text"`, `"integer"` o `"fecha"`, no como un tipo de base de datos.
            const domain_type = @field(entity.fields, field_name).type;

            // Si falta un codec, no se pueden parsear queries o JSON ni generar resultados.
            // Se informa ahora la entidad y el campo para no descubrir la omisión
            // al atender una solicitud en runtime.
            if (!@hasField(@TypeOf(codecs), domain_type))
                @compileError("entity '" ++ entity_name ++ "', field '" ++ field_name ++ "': missing REST codec for domain type '" ++ domain_type ++ "'");

            // No alcanza con tener un campo con el nombre correcto. Su valor debe
            // ser un `Codec` real: sus campos de punteros a función exigen
            // las tres firmas de conversión en compilación.
            if (!isCodec(@TypeOf(@field(codecs, domain_type))))
                @compileError("REST codec '" ++ domain_type ++ "': must be a zigma_rest.Codec");
        }
    }

    // El resultado es un tipo struct anónimo especializado para estas entidades
    // y codecs. No se generan archivos fuente del controlador: este tipo *es*
    // el controlador generado y se compila como código Zig escrito a mano.
    return struct {
        // Dentro del struct anónimo devuelto no hay un nombre de tipo en el código;
        // `@This()` lo provee para los receptores de métodos y los tipos de retorno.
        const Self = @This();

        // Los metadatos de rutas son una constante comptime y se pueden inspeccionar
        // sin construir `Self`. Contienen una ruta `/api/<entity>` por entidad
        // y los cuatro métodos CRUD permitidos.
        pub const routes = routeList(model_info);

        // A diferencia del schema, la configuración es estado de runtime: el mismo
        // tipo API generado puede instanciarse con distintos límites de cuerpo de solicitud.
        config: Config,

        // Un constructor convencional explicita la inicialización y permite agregar
        // campos de runtime en el futuro sin cambiar el código que lo llama.
        pub fn init(config: Config) Self {
            // Zig infiere `Self` del tipo de retorno declarado: acá solo hace falta
            // escribir el campo que se inicializa.
            return .{ .config = config };
        }

        // `handle` es el punto de entrada independiente del transporte. `std_http`
        // convierte una solicitud de socket en `Request`; los tests pueden llamar directamente.
        pub fn handle(
            // Se usa un puntero porque la API generada contiene configuración de runtime
            // y podría incorporar estado mutable, aunque ahora sea de solo lectura.
            self: *Self,
            // Quien llama debe liberar el `Response.body` reservado y devuelto acá.
            allocator: std.mem.Allocator,
            // El repositorio tiene tipado estructural: una implementación falsa y la de
            // PostgreSQL funcionan sin herencia, objeto de interfaz ni dependencia
            // directa de este módulo respecto de libpq.
            repository: anytype,
            // El método, destino, headers y cuerpo ya son independientes del transporte.
            request: Request,
        ) !Response {
            // El parseo crea muchos strings, arrays y nodos JSON de corta duración.
            // Una arena por solicitud permite liberarlos en una sola acción determinista.
            var scratch = std.heap.ArenaAllocator.init(allocator);
            // Esto corre en cada salida, incluidos errores y respuestas HTTP anticipadas,
            // y libera juntas todas las reservas temporales de la solicitud.
            defer scratch.deinit();
            // Los helpers y repositorios reciben este allocator para valores temporales;
            // solo la respuesta final usa el allocator de quien llama.
            const scratch_allocator = scratch.allocator();

            // Rechaza cuerpos demasiado grandes antes de parsear JSON o acceder al
            // repositorio. El adaptador de sockets también impone el límite al leer;
            // esta comprobación protege por igual las llamadas directas a `handle`.
            if (request.body.len > self.config.max_body_bytes)
                return requestValidationResponse(allocator, error.BodyTooLarge);

            // Busca una sola vez el primer separador de query. `null` indica que
            // el destino de esta solicitud contiene únicamente una ruta.
            const question = std.mem.indexOfScalar(u8, request.target, '?');
            // La ruta excluye `?` y todo lo que sigue. Los slices toman prestado
            // el destino inmutable de la solicitud, sin reservar memoria ni copiarlo.
            const path = if (question) |index| request.target[0..index] else request.target;
            // Del mismo modo, la query son los bytes posteriores a `?` o un slice vacío.
            const query = if (question) |index| request.target[index + 1 ..] else "";

            // Este controlador generado gestiona solo el espacio `/api/`. Otro
            // adaptador o router puede atender verificaciones de estado o archivos estáticos.
            if (!std.mem.startsWith(u8, path, "/api/"))
                return errorResponse(allocator, 404, "not_found", "Route not found");

            // Se quitan cinco bytes porque `"/api/".len == 5`; el resto debe ser
            // exactamente un nombre de entidad, como `"docentes"`.
            const entity_path = path[5..];
            // Los nombres vacíos y los segmentos anidados no son rutas de colecciones
            // de entidades; esta fase no incluye rutas con forma `/api/entity/id`.
            if (entity_path.len == 0 or std.mem.indexOfScalar(u8, entity_path, '/') != null)
                return errorResponse(allocator, 404, "not_found", "Route not found");

            // Este bucle comptime genera una rama normal de comparación de strings por
            // entidad conocida. Runtime elige una rama, pero el handler seleccionado
            // está especializado con un nombre de entidad y un schema comptime.
            inline for (@typeInfo(@TypeOf(model_info)).@"struct".field_names) |entity_name| {
                // Los nombres de entidades provienen solo de la SSOT validada: texto
                // arbitrario de la URL nunca puede convertirse después en identificador
                // PostgreSQL.
                if (std.mem.eql(u8, entity_path, entity_name))
                    return handleEntity(self, allocator, scratch_allocator, repository, request, query, entity_name);
            }

            // La ruta tenía la forma correcta, pero no nombraba ninguna entidad de la SSOT.
            return errorResponse(allocator, 404, "not_found", "Entity not found");
        }

        // Este helper contiene la validación y el comportamiento CRUD de la entidad.
        // Sigue siendo genérico respecto del repositorio, pero se especializa por entidad.
        fn handleEntity(
            self: *Self,
            // Los bytes de la respuesta JSON final deben sobrevivir a esta función:
            // usan el allocator de respuesta de quien llama.
            response_allocator: std.mem.Allocator,
            // Los filtros decodificados, JSON parseado y filas de base son locales a la
            // solicitud.
            scratch_allocator: std.mem.Allocator,
            repository: anytype,
            request: Request,
            query: []const u8,
            // Este parámetro es clave: permite que `@field` e `inline for` usen el
            // schema exacto de la entidad al compilar cada rama generada.
            comptime entity_name: []const u8,
        ) !Response {
            // `handle` necesitaba `self` para acceder a la configuración; este helper no
            // necesita estado de instancia por ahora. Descartarlo explícitamente satisface
            // la comprobación Zig de parámetros sin uso y documenta esa decisión.
            _ = self;

            // Como `entity_name` se conoce en comptime, esto selecciona la definición
            // concreta de entidad sin buscar en un mapa de runtime.
            const entity = @field(model_info, entity_name);

            // Divide `a=b&c=d`, decodifica escapes porcentuales de ambos lados,
            // valida UTF-8 y rechaza nombres de parámetro duplicados. Los fallos son errores
            // del cliente.
            const raw_filters = parseFilters(scratch_allocator, query) catch |err|
                return requestValidationResponse(response_allocator, err);

            // El parseo solo comprueba la sintaxis. Este paso impide filtrar por un
            // nombre que no sea un campo de la entidad seleccionada.
            if (!validateFilterNames(entity, raw_filters))
                return requestValidationResponse(response_allocator, error.UnknownFilter);

            // Recorre campos en orden SSOT, invoca el codec de query de cada dominio
            // y produce valores canónicos para el repositorio. El orden de parámetros de
            // la URL no puede cambiar el orden de placeholders ni el texto SQL generado.
            const filters = buildFilters(scratch_allocator, entity, codecs, raw_filters) catch |err|
                return requestValidationResponse(response_allocator, err);

            // Los cuatro métodos CRUD comparten la preparación de rutas y filtros;
            // se separan recién cuando la solicitud está ligada a un schema de entidad válido.
            switch (request.method) {
                .GET => {
                    // GET admite cero filtros (`SELECT *`) o cualquier cantidad de
                    // filtros de igualdad que el repositorio combina con `AND`.
                    var result = repository.select(scratch_allocator, entity_name, filters) catch |err|
                        // Los errores del repositorio se traducen de forma centralizada: los
                        // conflictos de restricciones, la indisponibilidad y los fallos
                        // internos
                        // no exponen diagnósticos de PostgreSQL en la respuesta HTTP.
                        return repositoryErrorResponse(response_allocator, err);

                    // Los resultados contienen columnas y filas propias y deben liberarlas
                    // en cada salida de la serialización. Con libpq, esto libera su arena.
                    defer result.deinit();

                    // GET genera un array JSON y devuelve 200. El `false` final indica
                    // que se esperan cero o más filas, no una fila obligatoria.
                    return renderResult(response_allocator, scratch_allocator, entity, codecs, result, 200, false) catch |err| switch (err) {
                        // La falta de memoria es un fallo de infraestructura y se propaga por
                        // el canal de errores de Zig, sin simular una respuesta HTTP válida
                        // que podría necesitar a su vez reservar memoria.
                        error.OutOfMemory => error.OutOfMemory,
                        // Columnas, anchos de fila o valores de base incorrectos indican
                        // un contrato roto entre repositorio y codec, no entrada inválida:
                        // el cliente recibe 500 sin detalles internos.
                        else => errorResponse(response_allocator, 500, "invalid_repository_result", "Repository returned an invalid row shape"),
                    };
                },

                .POST => {
                    // POST crea una entidad y no acepta filtros de selección.
                    // Rechazarlos evita una semántica de inserción ambigua.
                    if (query.len != 0) return requestValidationResponse(response_allocator, error.UnexpectedQuery);

                    // El cuerpo JSON de una mutación se interpreta solo si el tipo de contenido
                    // es `application/json`. `contentTypeIsJson` acepta parámetros
                    // como charset.
                    if (!contentTypeIsJson(request.content_type))
                        return requestValidationResponse(response_allocator, error.UnsupportedMediaType);

                    // Parsea al árbol JSON dinámico de Zig, pero exige que la raíz
                    // sea exactamente un objeto, no un array ni un escalar.
                    var parsed = parseJsonObject(scratch_allocator, request.body) catch |err|
                        return requestValidationResponse(response_allocator, err);
                    // Aunque la arena temporal contiene los bytes, `Parsed.deinit` conserva
                    // el contrato de gestión de memoria de la API JSON y sería necesario
                    // si se usara un allocator distinto de una arena.
                    defer parsed.deinit();

                    // Ignorar propiedades mal escritas en silencio sería peligroso:
                    // cada miembro JSON debe corresponder a un campo de la entidad.
                    if (objectHasUnknownField(entity, parsed.value.object))
                        return requestValidationResponse(response_allocator, error.UnknownBodyField);

                    // Recorre campos en orden SSOT, exige PK y campos efectivamente NOT NULL,
                    // completa los nullable omitidos con SQL NULL y pasa cada valor
                    // no-null por el codec JSON de su dominio.
                    const values = buildInsertValues(scratch_allocator, entity, codecs, parsed.value.object) catch |err|
                        return requestValidationResponse(response_allocator, err);

                    // Los validadores de negocio reciben la fila completa normalizada,
                    // incluidos los SQL NULL que completan propiedades nullable omitidas.
                    if (comptime @hasField(@TypeOf(checked_validators), entity_name)) {
                        const validator = @field(checked_validators, entity_name);
                        const violation = validator.validate(values) catch
                            return errorResponse(response_allocator, 500, "business_validation_error", "Business validation could not be completed");
                        if (violation) |details|
                            return businessViolationResponse(response_allocator, details);
                    }

                    // El repositorio emite INSERT ... RETURNING * parametrizado.
                    var result = repository.insert(scratch_allocator, entity_name, values) catch |err|
                        return repositoryErrorResponse(response_allocator, err);
                    defer result.deinit();

                    // Un POST exitoso devuelve 201 y exactamente una fila;
                    // `single = true` convierte cualquier otra cantidad en un error de contrato.
                    return renderResult(response_allocator, scratch_allocator, entity, codecs, result, 201, true) catch |err| switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => errorResponse(response_allocator, 500, "invalid_repository_result", "Repository returned an invalid row shape"),
                    };
                },

                .PUT => {
                    // Esta API no admite actualizaciones masivas sin restricciones:
                    // al menos un filtro de igualdad debe identificar las filas destino.
                    if (filters.len == 0) return requestValidationResponse(response_allocator, error.FilterRequired);

                    // Los cuerpos PUT usan la misma política de tipo de contenido JSON que
                    // POST.
                    if (!contentTypeIsJson(request.content_type))
                        return requestValidationResponse(response_allocator, error.UnsupportedMediaType);

                    // Exige un único objeto JSON con la actualización parcial.
                    var parsed = parseJsonObject(scratch_allocator, request.body) catch |err|
                        return requestValidationResponse(response_allocator, err);
                    defer parsed.deinit();

                    // Rechaza campos desconocidos antes de calcular los valores de
                    // actualización.
                    if (objectHasUnknownField(entity, parsed.value.object))
                        return requestValidationResponse(response_allocator, error.UnknownBodyField);

                    // Este helper exige un cuerpo parcial no vacío, rechaza cambios de PK,
                    // comprueba nulabilidad y aplica codecs JSON. Emite los valores
                    // en orden de campos de la entidad para generar SQL estable.
                    const values = buildUpdateValues(scratch_allocator, entity, codecs, parsed.value.object) catch |err|
                        return requestValidationResponse(response_allocator, err);

                    // Una actualización parcial no se puede validar por sí sola: la regla
                    // puede depender de una columna que no cambia. Solo las entidades con
                    // un validador registrado ejecutan este SELECT preparatorio.
                    if (comptime @hasField(@TypeOf(checked_validators), entity_name)) {
                        var current = repository.select(scratch_allocator, entity_name, filters) catch |err|
                            return repositoryErrorResponse(response_allocator, err);
                        defer current.deinit();

                        const validator = @field(checked_validators, entity_name);
                        const violation = validateUpdatedRows(entity, current, values, validator) catch |err| switch (err) {
                            error.InvalidRepositoryResult => return errorResponse(response_allocator, 500, "invalid_repository_result", "Repository returned an invalid row shape"),
                            error.InvalidState => return errorResponse(response_allocator, 500, "business_validation_error", "Business validation could not be completed"),
                        };
                        if (violation) |details|
                            return businessViolationResponse(response_allocator, details);
                    }

                    // El repositorio produce UPDATE ... WHERE ... RETURNING * parametrizado
                    // y numera los valores de actualización antes que los de filtros.
                    var result = repository.update(scratch_allocator, entity_name, values, filters) catch |err|
                        return repositoryErrorResponse(response_allocator, err);
                    defer result.deinit();

                    // PUT devuelve un array porque el filtro puede coincidir con cero,
                    // una o varias filas. Cero coincidencias produce `200 []`, no 404.
                    return renderResult(response_allocator, scratch_allocator, entity, codecs, result, 200, false) catch |err| switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => errorResponse(response_allocator, 500, "invalid_repository_result", "Repository returned an invalid row shape"),
                    };
                },

                .DELETE => {
                    // Como en PUT, se rechaza la eliminación sin restricciones.
                    if (filters.len == 0) return requestValidationResponse(response_allocator, error.FilterRequired);

                    // DELETE no tiene cuerpo JSON; los filtros ya validados bastan
                    // para DELETE ... RETURNING * parametrizado.
                    var result = repository.delete(scratch_allocator, entity_name, filters) catch |err|
                        return repositoryErrorResponse(response_allocator, err);
                    defer result.deinit();

                    // Devuelve todas las filas eliminadas como array. Sin coincidencias,
                    // devuelve `200 []` exitoso porque la solicitud sigue siendo válida.
                    return renderResult(response_allocator, scratch_allocator, entity, codecs, result, 200, false) catch |err| switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => errorResponse(response_allocator, 500, "invalid_repository_result", "Repository returned an invalid row shape"),
                    };
                },

                // `.other` representa los métodos std.http ajenos al contrato CRUD de esta
                // fase, incluidos PATCH y HEAD. La ruta de entidad existe: corresponde
                // 405 en lugar de 404.
                .other => return errorResponse(response_allocator, 405, "method_not_allowed", "Allowed methods: GET, POST, PUT, DELETE"),
            }
        }
    };
}
