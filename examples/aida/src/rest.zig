//! Codecs y validadores tipados de AIDA para el controlador REST generado.

const zigma = @import("zigma");
const rest = @import("zigma_rest");
const aida = @import("aida");
const fecha_wire = @import("fecha_wire.zig");
const context = @import("validation_context.zig");
pub const ValidationContext = context.ValidationContext;
pub const ContextProvider = context.ContextProvider;
pub const contextFromTimestamp = context.contextFromTimestamp;

pub const codecs = rest.defineCodecs(aida.type_defs, zigma.merge(.{
    rest.common_codecs,
    .{
        .fecha = fecha_wire.codec,
        .email = rest.text_codec,
    },
}));

/// Permite probar directamente el codec de Fecha.
pub const date_codec = fecha_wire.codec;

fn validateDocenteBusinessRules(value: aida.Docente, request_context: ValidationContext) ?rest.BusinessRuleViolation {
    aida.validarDocente(value, request_context.today) catch |err| return switch (err) {
        error.TeoricoRequiereCincoAniosExperiencia => .{
            .code = "teorico_requires_five_years_experience",
            .message = "A docente with cargo 'teorico' requires at least 5 years of experiencia",
        },
        error.TeoricoRequiereFechaNacimiento => .{
            .code = "teorico_requires_birth_date",
            .message = "A docente with cargo 'teorico' requires fecha_nacimiento",
        },
        error.TeoricoRequiereTreintaAnios => .{
            .code = "teorico_requires_thirty_years",
            .message = "A docente with cargo 'teorico' must be at least 30 years old",
        },
        error.FutureDate => .{
            .code = "birth_date_in_future",
            .message = "A docente's birth date cannot be in the future",
        },
        // El codec y el proveedor validan las fechas antes de esta llamada.
        // Se conserva un resultado explícito para quien invoque el adaptador directamente.
        error.InvalidDate => .{
            .code = "invalid_birth_date",
            .message = "A docente's birth date must be a valid civil date",
        },
    };
    return null;
}

pub const business_validators = rest.defineBusinessValidators(aida.Model, .{
    .docentes = rest.BusinessValidator(aida.Docente, ValidationContext){ .validate = validateDocenteBusinessRules },
});

pub const Api = rest.Api(aida.Model, codecs, business_validators);
