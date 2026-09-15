//! Codecs REST de AIDA y tipo del controlador generado a partir de las mismas entidades.

const std = @import("std");
const zigma = @import("zigma");
const rest = @import("zigma_rest");
const aida = @import("aida");

fn validIsoDate(value: []const u8) bool {
    // Valida el formato externo exacto YYYY-MM-DD antes de indexar los slices.
    if (value.len != 10 or value[4] != '-' or value[7] != '-') return false;
    for (value, 0..) |byte, index| {
        if (index == 4 or index == 7) continue;
        if (!std.ascii.isDigit(byte)) return false;
    }
    const year = std.fmt.parseInt(u16, value[0..4], 10) catch return false;
    const month = std.fmt.parseInt(u8, value[5..7], 10) catch return false;
    const day = std.fmt.parseInt(u8, value[8..10], 10) catch return false;
    if (month == 0 or month > 12 or day == 0) return false;
    // Las reglas gregorianas de años bisiestos hacen que el límite de febrero dependa del año.
    const leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
    const month_days = [_]u8{ 31, if (leap) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return day <= month_days[month - 1];
}

fn dateFromQuery(allocator: std.mem.Allocator, value: []const u8) rest.CodecError![]const u8 {
    // La representación textual de la fecha en PostgreSQL ya es ISO: alcanza con
    // validarla y crear una copia cuya memoria se libere al terminar la solicitud.
    if (!validIsoDate(value)) return error.InvalidValue;
    return allocator.dupe(u8, value) catch error.OutOfMemory;
}

fn dateFromJson(allocator: std.mem.Allocator, value: std.json.Value) rest.CodecError![]const u8 {
    if (value != .string or !validIsoDate(value.string)) return error.InvalidValue;
    return allocator.dupe(u8, value.string) catch error.OutOfMemory;
}

fn dateToJson(_: std.mem.Allocator, value: []const u8) rest.CodecError!std.json.Value {
    // También se valida la salida: un texto corrupto o inesperado de la base de
    // datos no debe convertirse en una respuesta exitosa de la API.
    if (!validIsoDate(value)) return error.InvalidValue;
    return .{ .string = value };
}

pub const date_codec = rest.Codec{
    .queryToPostgres = dateFromQuery,
    .jsonToPostgres = dateFromJson,
    .postgresToJson = dateToJson,
};

// Los dominios propios de la aplicación extienden el conjunto común. `email` es
// actualmente un alias semántico de texto; `fecha` agrega validación efectiva.
pub const codecs = rest.defineCodecs(aida.type_defs, zigma.merge(.{
    rest.common_codecs,
    .{
        .fecha = date_codec,
        .email = rest.text_codec,
    },
}));

fn fieldValue(values: []const rest.FieldValue, name: []const u8) ?rest.FieldValue {
    for (values) |value| {
        if (std.mem.eql(u8, value.name, name)) return value;
    }
    return null;
}

/// Adapta la fila completa normalizada del motor REST al estado de dominio reducido
/// que consume el validador de docente de AIDA, independiente del transporte.
fn validateDocenteBusinessRules(
    values: []const rest.FieldValue,
) rest.BusinessValidationError!?rest.BusinessRuleViolation {
    const cargo = (fieldValue(values, "cargo") orelse return error.InvalidState).value;
    const experiencia_text = (fieldValue(values, "experiencia") orelse return error.InvalidState).value;
    const experiencia = if (experiencia_text) |text|
        std.fmt.parseInt(i64, text, 10) catch return error.InvalidState
    else
        null;

    aida.validarDocente(.{
        .cargo = cargo,
        .experiencia = experiencia,
    }) catch return .{
        .code = "teorico_requires_five_years_experience",
        .message = "A docente with cargo 'teorico' requires at least 5 years of experiencia",
    };
    return null;
}

pub const business_validators = rest.defineBusinessValidators(aida.Model, .{
    .docentes = rest.BusinessValidator{ .validate = validateDocenteBusinessRules },
});

// Esta declaración especializa el controlador genérico en compilación;
// no abre un puerto ni se conecta a PostgreSQL.
pub const Api = rest.ApiWithBusinessValidators(aida.Model, codecs, business_validators);
