//! Registro de validadores por entidad y validación del estado resultante de un PUT.
//! Conserva el contrato textual actual; no consulta repositorios ni produce respuestas HTTP.

const std = @import("std");
const FieldValue = @import("types.zig").FieldValue;

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
pub fn validateUpdatedRows(
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
