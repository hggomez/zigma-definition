//! Frontend WASM genérico. El build inyecta un system con type_defs y entity_defs.

const std = @import("std");
const zigma = @import("zigma");
const system = @import("system");
const zigma_json = @import("zigma_json");

extern "env" fn js_send_post(ptr: [*]const u8, len: usize) void;

const Model = zigma.Framework(system.type_defs, system.entity_defs);
const entity_names = @typeInfo(@TypeOf(Model.info)).@"struct".field_names;

/// Mayor cantidad de campos; determina el tamaño del buffer de longitudes.
fn maxFieldCount() usize {
    var max: usize = 0;
    inline for (entity_names) |name| {
        const n = @typeInfo(Model.Row(name)).@"struct".field_names.len;
        if (n > max) max = n;
    }
    return max;
}

const max_field_count = maxFieldCount();

var input_buf: [8192]u8 = undefined;
var json_buf: [8192]u8 = undefined;
var schema_buf: [32768]u8 = undefined;
var schema_len_value: usize = 0;
var schema_ready: bool = false;
var json_len_value: usize = 0;
var lengths_buf: [max_field_count]usize = undefined;
var error_buf: [256]u8 = undefined;
var error_len_value: usize = 0;

/// Publica el error en un buffer independiente de la salida JSON.
fn setError(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(&error_buf, fmt, args) catch {
        const fallback = "error: could not build row JSON";
        @memcpy(error_buf[0..fallback.len], fallback);
        error_len_value = fallback.len;
        return;
    };
    error_len_value = msg.len;
}

/// Calcula y conserva el catálogo. Un desbordamiento deja longitud cero y un error.
fn schemaBytes() []const u8 {
    if (!schema_ready) {
        const s = zigma_json.stringifyEntityCatalog(Model, &schema_buf) catch {
            schema_len_value = 0;
            setError("error: catalogue exceeds schema buffer", .{});
            return schema_buf[0..0];
        };
        schema_len_value = s.len;
        schema_ready = true;
    }
    return schema_buf[0..schema_len_value];
}

export fn schema_ptr() [*]const u8 {
    return schemaBytes().ptr;
}

export fn schema_len() usize {
    return schemaBytes().len;
}

export fn input_ptr() [*]u8 {
    return &input_buf;
}

export fn input_len() usize {
    return input_buf.len;
}

export fn lengths_ptr() [*]usize {
    return &lengths_buf;
}

export fn json_ptr() [*]const u8 {
    return &json_buf;
}

export fn json_len() usize {
    return json_len_value;
}

export fn error_ptr() [*]const u8 {
    return &error_buf;
}

export fn error_len() usize {
    return error_len_value;
}

/// Interpreta las celdas como una fila de Model con nulabilidad efectiva de entidad.
fn buildRowJson(comptime entity_name: []const u8) usize {
    const Row = Model.Row(entity_name);
    var row: Row = undefined;
    var offset: usize = 0;
    inline for (@typeInfo(Row).@"struct".field_names, 0..) |name, i| {
        const len = lengths_buf[i];
        if (len > input_buf.len - offset) {
            setError("error: input too long", .{});
            return 0;
        }
        const bytes = input_buf[offset..][0..len];
        @field(row, name) = zigma_json.parseFieldValue(@FieldType(Row, name), bytes) catch {
            setError("error: {s}: not {s}", .{ name, zigma_json.fieldStorage(@FieldType(Row, name)) });
            return 0;
        };
        offset += len;
    }
    const json_slice = zigma_json.stringifyRecord(row, &json_buf) catch {
        setError("error: could not stringify row", .{});
        return 0;
    };
    json_len_value = json_slice.len;
    return json_slice.len;
}

/// El índice sigue el catálogo. Cada intento invalida el resultado anterior,
/// incluso si falla antes de seleccionar la entidad.
export fn build_row(entity_index: u32) usize {
    @setEvalBranchQuota(10000);
    json_len_value = 0;
    error_len_value = 0;
    inline for (entity_names, 0..) |name, i| {
        if (entity_index == i) return buildRowJson(name);
    }
    setError("error: unknown entity", .{});
    return 0;
}

/// Solo envía la solicitud si la fila completa pudo serializarse.
export fn create_row(entity_index: u32) usize {
    const len = build_row(entity_index);
    if (len == 0) return 0;
    js_send_post(json_buf[0..len].ptr, len);
    return len;
}
