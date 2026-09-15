//! Generic WASM frontend. The host build injects a `system` module that
//! exports `type_defs` and `entity_defs`.

const std = @import("std");
const zigma = @import("zigma");
const system = @import("system");
const zigma_json = @import("zigma_json");

extern "env" fn js_send_post(ptr: [*]const u8, len: usize) void;

const type_defs = system.type_defs;
const entity_defs = system.entity_defs;
const entity_names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;

/// Largest `.fields` count among `entity_defs`. No inputs. Used as `lengths_buf` length.
fn maxFieldCount() usize {
    var max: usize = 0;
    inline for (entity_names) |name| {
        const n = @typeInfo(@TypeOf(@field(entity_defs, name).fields)).@"struct".field_names.len;
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

/// Writes a build error into `error_buf` (`fmt` + `args`, or a fallback if it does not fit).
fn setError(comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.bufPrint(&error_buf, fmt, args) catch {
        const fallback = "error: could not build row JSON";
        @memcpy(error_buf[0..fallback.len], fallback);
        error_len_value = fallback.len;
        return;
    };
    error_len_value = msg.len;
}

/// Catalog JSON in `schema_buf` (filled once). Slice of that buffer; no inputs.
fn schemaBytes() []const u8 {
    if (!schema_ready) {
        const s = zigma_json.stringifyEntityCatalog(type_defs, entity_defs, &schema_buf) catch unreachable;
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

/// Parses packed `input_buf`/`lengths_buf` into `entity`'s `RecordInstanceType`, writes JSON to `json_buf`.
/// Returns that length, or 0 and sets `error_buf` if a cell is too long or not a value of the field type.
fn buildRowJson(comptime entity: anytype) usize {
    error_len_value = 0;
    const Row = zigma.RecordInstanceType(type_defs, entity.fields);
    var row: Row = undefined;
    var offset: usize = 0;
    inline for (@typeInfo(Row).@"struct".field_names, 0..) |name, i| {
        const len = lengths_buf[i];
        if (offset + len > input_buf.len) {
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

/// `entity_index` is the field order of `entity_defs` (same as the catalog array).
/// Packed strings in `input_buf`; per-field lengths in `lengths_buf`.
/// Returns the JSON length written to `json_buf`, or 0 on error.
export fn build_row(entity_index: u32) usize {
    @setEvalBranchQuota(10000);
    inline for (entity_names, 0..) |name, i| {
        if (entity_index == i) return buildRowJson(@field(entity_defs, name));
    }
    setError("error: unknown entity", .{});
    return 0;
}

/// Same as `build_row`; on success also calls `js_send_post` with that JSON. Returns the length, or 0 on error.
export fn create_row(entity_index: u32) usize {
    const len = build_row(entity_index);
    if (len == 0) return 0;
    js_send_post(json_buf[0..len].ptr, len);
    return len;
}
