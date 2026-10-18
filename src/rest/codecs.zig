//! Codecs de dominio entre HTTP/JSON y la representación textual del repositorio.
//! Los valores null se resuelven en request.zig y response.zig, fuera de los codecs.

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

// Comprobación interna usada por Api; mantiene diagnósticos por entidad y campo.
pub fn checkModelCodecs(comptime Model: type, comptime codecs: anytype) void {
    const model_info = Model.info;
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
}
