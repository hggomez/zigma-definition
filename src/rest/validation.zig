//! Registro de validadores por entidad y validación del estado resultante de un PUT.
//! Convierte filas textuales a entidades concretas; no consulta repositorios ni produce HTTP.

const std = @import("std");
const FieldValue = @import("types.zig").FieldValue;

/// Descripción estable, visible para el cliente, de un estado de negocio rechazado.
/// Los validadores son código de aplicación; el motor REST construye la respuesta HTTP de
/// error.
pub const BusinessRuleViolation = struct {
    code: []const u8,
    message: []const u8,
};

/// La regla recibe la entidad registrada y un contexto de aplicación explícito.
/// Es síncrona: no puede retener referencias a esos valores después de la llamada.
pub fn BusinessValidator(comptime T: type, comptime C: type) type {
    return struct {
        pub const Context = C;
        validate: *const fn (T, C) ?BusinessRuleViolation,
    };
}

// Una fila textual inválida es un error interno; la falta de memoria se propaga.
const DecodeError = error{ InvalidState, InvalidRepositoryResult, OutOfMemory };

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
        const Validator = @TypeOf(@field(validators, entity_name));
        const diagnostic = "REST business validator '" ++ entity_name ++ "': must be a zigma_rest.BusinessValidator(Model.Row(\"" ++ entity_name ++ "\"), Context)";
        if (@typeInfo(Validator) != .@"struct") @compileError(diagnostic);
        if (!@hasDecl(Validator, "Context")) @compileError(diagnostic);
        if (@TypeOf(Validator.Context) != type) @compileError(diagnostic);
        if (Validator != BusinessValidator(Model.Row(entity_name), Validator.Context)) @compileError(diagnostic);
        if (Validator.Context != ContextOf(validators))
            @compileError("REST business validator '" ++ entity_name ++ "': validation context must match other validators");
    }
    return validators;
}

/// El registro ya comprobado comparte un único contexto de aplicación.
/// Sin validadores, no necesita datos adicionales de runtime.
pub fn ContextOf(comptime validators: anytype) type {
    const names = @typeInfo(@TypeOf(validators)).@"struct".field_names;
    if (names.len == 0) return void;
    return @TypeOf(@field(validators, names[0])).Context;
}

/// Materializa la fila usando los codecs actuales y un árbol JSON en memoria.
/// El allocator es el de la arena de solicitud. Los codecs pueden prestar slices
/// del resultado textual: el llamador debe conservarlo mientras usa la fila.
pub fn decodeRow(
    comptime Model: type,
    comptime entity_name: []const u8,
    comptime codecs: anytype,
    allocator: std.mem.Allocator,
    values: []const FieldValue,
) DecodeError!Model.Row(entity_name) {
    const fields = @field(Model.info, entity_name).fields;
    const names = @typeInfo(@TypeOf(fields)).@"struct".field_names;
    if (values.len != names.len) return error.InvalidRepositoryResult;
    var object: std.json.ObjectMap = .empty;
    inline for (names, 0..) |name, index| {
        if (!std.mem.eql(u8, values[index].name, name)) return error.InvalidRepositoryResult;
        const field = @field(fields, name);
        const value: std.json.Value = if (values[index].value) |bytes|
            @field(codecs, field.type).postgresToJson(allocator, bytes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidValue => return error.InvalidState,
            }
        else blk: {
            if (!field.nullable) return error.InvalidState;
            break :blk .null;
        };
        try object.put(allocator, name, value);
    }
    return std.json.parseFromValueLeaky(Model.Row(entity_name), allocator, .{ .object = object }, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidState,
    };
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
    comptime Model: type,
    comptime entity_name: []const u8,
    comptime codecs: anytype,
    allocator: std.mem.Allocator,
    current: anytype,
    updates: []const FieldValue,
    validator: anytype,
    context: @TypeOf(validator).Context,
) DecodeError!?BusinessRuleViolation {
    const entity = @field(Model.info, entity_name);
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
        const value = try decodeRow(Model, entity_name, codecs, allocator, &merged);
        if (validator.validate(value, context)) |violation| return violation;
    }
    return null;
}
