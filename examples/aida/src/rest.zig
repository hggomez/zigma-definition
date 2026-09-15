//! Codecs REST de AIDA y tipo del controlador generado.
//! No conoce formas de dominio: solo registra codecs aportados junto al sistema.

const std = @import("std");
const zigma = @import("zigma");
const rest = @import("zigma_rest");
const aida = @import("aida");
const fecha_wire = @import("fecha_wire.zig");

pub const codecs = rest.defineCodecs(aida.type_defs, zigma.merge(.{
    rest.common_codecs,
    .{
        .fecha = fecha_wire.codec,
        .email = rest.text_codec,
    },
}));

/// Re-export for tests that exercise the fecha wire codec directly.
pub const date_codec = fecha_wire.codec;

fn fieldValue(values: []const rest.FieldValue, name: []const u8) ?rest.FieldValue {
    for (values) |value| {
        if (std.mem.eql(u8, value.name, name)) return value;
    }
    return null;
}

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

pub const Api = rest.ApiWithBusinessValidators(aida.Model, codecs, business_validators);
