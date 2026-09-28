//! Serialización de resultados y traducción de errores a respuestas HTTP estables.
//! El cuerpo final pertenece al allocator del llamador; los codecs pueden usar
//! la arena temporal mientras los resultados del repositorio siguen vigentes.

const std = @import("std");
const types = @import("types.zig");
const validation = @import("validation.zig");
const Response = types.Response;
const BusinessRuleViolation = validation.BusinessRuleViolation;

fn jsonResponse(allocator: std.mem.Allocator, status: u16, value: anytype) !Response {
    // El writer con allocator produce un cuerpo contiguo y transfiere su memoria
    // a Response. Después se pueden descartar los datos temporales de la solicitud.
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var stringify: std.json.Stringify = .{ .writer = &output.writer };
    try stringify.write(value);
    return .{ .status = status, .body = try output.toOwnedSlice() };
}

pub fn errorResponse(allocator: std.mem.Allocator, status: u16, code: []const u8, message: []const u8) !Response {
    // Un único constructor mantiene uniforme la estructura de errores visible para el cliente.
    return jsonResponse(allocator, status, .{ .@"error" = .{ .code = code, .message = message } });
}

pub fn repositoryErrorResponse(allocator: std.mem.Allocator, err: anyerror) !Response {
    // Solo las categorías estables cruzan la interfaz HTTP. Los diagnósticos
    // PostgreSQL quedan privados, sin exponer detalles del schema ni de la conexión.
    return switch (err) {
        error.Conflict => errorResponse(allocator, 409, "constraint_conflict", "PostgreSQL constraint rejected the operation"),
        error.Unavailable => errorResponse(allocator, 503, "database_unavailable", "Database is unavailable"),
        error.OutOfMemory => error.OutOfMemory,
        else => errorResponse(allocator, 500, "database_error", "Database operation failed"),
    };
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

pub fn requestValidationResponse(allocator: std.mem.Allocator, err: anyerror) !Response {
    // Varios errores internos de validación se reducen a un único contrato 400 seguro;
    // solo el tamaño del cuerpo y el tipo de contenido reciben estados distintos.
    return switch (err) {
        error.BodyTooLarge => errorResponse(allocator, 413, "body_too_large", "Request body exceeds the configured limit"),
        error.UnsupportedMediaType => errorResponse(allocator, 415, "unsupported_media_type", "Expected application/json"),
        else => errorResponse(allocator, 400, "invalid_request", "Request fields or values are invalid"),
    };
}

pub fn businessViolationResponse(
    allocator: std.mem.Allocator,
    violation: BusinessRuleViolation,
) !Response {
    return errorResponse(allocator, 422, violation.code, violation.message);
}

/// Serializa filas y mantiene uniforme el tratamiento de resultados inválidos.
/// La falta de memoria se propaga por el canal de errores Zig; las columnas,
/// anchos de fila o valores incompatibles producen un 500 sin detalles internos.
pub fn fromResult(
    response_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    comptime entity: anytype,
    comptime codecs: anytype,
    result: anytype,
    status: u16,
    single: bool,
) !Response {
    return renderResult(response_allocator, scratch_allocator, entity, codecs, result, status, single) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => errorResponse(response_allocator, 500, "invalid_repository_result", "Repository returned an invalid row shape"),
    };
}
