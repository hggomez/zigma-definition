//! Parsing y normalización de solicitudes según los metadatos de Model.
//! Los valores temporales pertenecen a la arena de la solicitud creada por Api.handle.
//! No escribe en repositorios ni construye respuestas HTTP.

const std = @import("std");
const types = @import("types.zig");
const FieldValue = types.FieldValue;

// Los filtros de query no pueden expresar SQL NULL en esta primera versión REST.
const RawFilter = struct { name: []const u8, value: []const u8 };

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

pub fn buildInsertValues(
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

pub fn buildUpdateValues(
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

fn parseJsonObject(allocator: std.mem.Allocator, body: []const u8) !std.json.Parsed(std.json.Value) {
    // Los nodos parseados viven en la arena de la solicitud. Solo se acepta un objeto;
    // los arrays para operaciones masivas quedan fuera de la fase 3.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidJson;
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;
    return parsed;
}

/// Parsea la query, rechaza filtros desconocidos y los ordena según la entidad.
/// El orden de la URL no modifica el orden de los parámetros del repositorio.
pub fn decodeFilters(
    allocator: std.mem.Allocator,
    comptime entity: anytype,
    comptime codecs: anytype,
    query: []const u8,
) ![]FieldValue {
    const raw = try parseFilters(allocator, query);
    if (!validateFilterNames(entity, raw)) return error.UnknownFilter;
    return buildFilters(allocator, entity, codecs, raw);
}

/// POST y PUT comparten la lectura de un objeto JSON con campos conocidos.
/// Admite parámetros en Content-Type, como charset; el llamador libera el Parsed
/// aun cuando sus nodos pertenezcan a la arena temporal de handle.
pub fn parseBody(
    allocator: std.mem.Allocator,
    comptime entity: anytype,
    request: types.Request,
) !std.json.Parsed(std.json.Value) {
    if (!contentTypeIsJson(request.content_type)) return error.UnsupportedMediaType;
    const parsed = try parseJsonObject(allocator, request.body);
    errdefer parsed.deinit();
    if (objectHasUnknownField(entity, parsed.value.object)) return error.UnknownBodyField;
    return parsed;
}
