//! Codecs y validadores tipados de AIDA para el controlador REST generado.

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

/// Permite probar directamente el codec de Fecha.
pub const date_codec = fecha_wire.codec;

fn validateDocenteBusinessRules(value: aida.Docente) ?rest.BusinessRuleViolation {
    aida.validarDocente(value) catch return .{
        .code = "teorico_requires_five_years_experience",
        .message = "A docente with cargo 'teorico' requires at least 5 years of experiencia",
    };
    return null;
}

pub const business_validators = rest.defineBusinessValidators(aida.Model, .{
    .docentes = rest.BusinessValidator(aida.Docente) { .validate = validateDocenteBusinessRules },
});

pub const Api = rest.Api(aida.Model, codecs, business_validators);
