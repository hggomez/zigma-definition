//! Catálogo de entidades desde Model y serialización JSON en buffers del llamador.
//! `storage` describe el control de la interfaz; `type` conserva el dominio del contrato.
//! La escritura usa std.json y no reserva memoria. El parser de celdas conserva
//! sus reglas: vacío → null para opcionales, texto obligatorio vacío → InvalidValue.
//! No conoce sistemas concretos, HTTP ni PostgreSQL.

const std = @import("std");

/// Serializa una fila Zig; el resultado pertenece al buffer recibido.
pub fn stringifyRecord(row: anytype, buf: []u8) error{NoSpaceLeft}![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    std.json.Stringify.value(row, .{}, &writer) catch return error.NoSpaceLeft;
    return writer.buffered();
}

/// Serializa un conjunto de filas como un array JSON compacto.
pub fn stringifyRecords(rows: anytype, buf: []u8) error{NoSpaceLeft}![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    var json: std.json.Stringify = .{ .writer = &writer };
    json.beginArray() catch return error.NoSpaceLeft;
    for (rows) |row| json.write(row) catch return error.NoSpaceLeft;
    json.endArray() catch return error.NoSpaceLeft;
    return writer.buffered();
}

/// Conserva la proyección de un record independiente como [{name,label},…].
pub fn stringifyRecordSchema(rec_info: anytype, buf: []u8) error{NoSpaceLeft}![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    var json: std.json.Stringify = .{ .writer = &writer };
    json.beginArray() catch return error.NoSpaceLeft;
    inline for (@typeInfo(@TypeOf(rec_info)).@"struct".field_names) |name| {
        json.write(.{ .name = name, .label = @field(rec_info, name).label }) catch return error.NoSpaceLeft;
    }
    json.endArray() catch return error.NoSpaceLeft;
    return writer.buffered();
}

/// Page widget shape for Zig type `T`: `"text"` / `"integer"` / `"boolean"` / `"object"`.
/// Optionals use the child shape (`?i64` → `"integer"`). Compile error if unsupported.
pub fn fieldStorage(comptime T: type) []const u8 {
    switch (@typeInfo(T)) {
        .optional => |o| return fieldStorage(o.child),
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) return "text";
            @compileError("unsupported field type " ++ @typeName(T));
        },
        .int => return "integer",
        .bool => return "boolean",
        .@"struct" => return "object",
        else => @compileError("unsupported field type " ++ @typeName(T)),
    }
}

/// Cell string → `T`. Structs are JSON objects with `T`'s field names.
/// `[]const u8` values alias `bytes`, including string fields inside a struct
/// (the same contract as a top-level text cell). JSON strings that need an
/// unescape copy would live in parse scratch and are `error.InvalidValue`.
/// An empty cell is Zig `null` for `?T` and `error.InvalidValue` for required
/// `[]const u8`. The literal `"null"` is never absence: for text it is the
/// string `"null"`; for other domains it is `InvalidValue`.
pub fn parseFieldValue(comptime T: type, bytes: []const u8) error{InvalidValue}!T {
    switch (@typeInfo(T)) {
        .optional => |optional| {
            if (bytes.len == 0) return null;
            return try parseFieldValue(optional.child, bytes);
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                if (bytes.len == 0) return error.InvalidValue;
                return bytes;
            }
            @compileError("unsupported field type " ++ @typeName(T));
        },
        .int => return std.fmt.parseInt(T, bytes, 10) catch error.InvalidValue,
        .bool => {
            if (std.mem.eql(u8, bytes, "true")) return true;
            if (std.mem.eql(u8, bytes, "false")) return false;
            return error.InvalidValue;
        },
        .@"struct" => |s| {
            if (s.is_tuple) @compileError("unsupported field type " ++ @typeName(T));
            var buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const value = std.json.parseFromSliceLeaky(T, fba.allocator(), bytes, .{
                .allocate = .alloc_if_needed,
            }) catch return error.InvalidValue;
            if (!slicesInsideInput(T, value, bytes)) return error.InvalidValue;
            return value;
        },
        else => @compileError("unsupported field type " ++ @typeName(T)),
    }
}

/// True if every `[]const u8` in `value` is a subslice of `input` (no unescape copies). Used after parsing a struct cell.
fn slicesInsideInput(comptime T: type, value: T, input: []const u8) bool {
    switch (@typeInfo(T)) {
        .pointer => |p| {
            if (p.size != .slice or p.child != u8) return true;
            const start = @intFromPtr(input.ptr);
            const ptr = @intFromPtr(value.ptr);
            return ptr >= start and ptr + value.len <= start + input.len;
        },
        .@"struct" => |st| {
            if (st.is_tuple) return true;
            inline for (st.field_names) |name| {
                if (!slicesInsideInput(@FieldType(T, name), @field(value, name), input)) return false;
            }
            return true;
        },
        else => return true,
    }
}

/// Serializa una entidad normalizada y su forma para los controles del frontend.
pub fn stringifyEntitySchema(comptime Model: type, comptime entity_name: []const u8, buf: []u8) error{NoSpaceLeft}![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    var json: std.json.Stringify = .{ .writer = &writer };
    writeEntity(&json, Model, entity_name) catch return error.NoSpaceLeft;
    return writer.buffered();
}

/// Catálogo en orden de declaración. Las reglas de aplicación no se publican aquí.
pub fn stringifyEntityCatalog(comptime Model: type, buf: []u8) error{NoSpaceLeft}![]const u8 {
    var writer = std.Io.Writer.fixed(buf);
    var json: std.json.Stringify = .{ .writer = &writer };
    json.beginArray() catch return error.NoSpaceLeft;
    inline for (@typeInfo(@TypeOf(Model.info)).@"struct".field_names) |name| {
        writeEntity(&json, Model, name) catch return error.NoSpaceLeft;
    }
    json.endArray() catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn writeEntity(json: *std.json.Stringify, comptime Model: type, comptime name: []const u8) std.json.Stringify.Error!void {
    // Row también localiza el error de una entidad desconocida antes de acceder a info.
    const Row = Model.Row(name);
    const entity = @field(Model.info, name);
    try json.beginObject();
    try json.objectField("name");
    try json.write(name);
    try json.objectField("pk");
    try json.write(entity.pk);
    try json.objectField("uks");
    try json.beginObject();
    inline for (@typeInfo(@TypeOf(entity.uks)).@"struct".field_names) |key| {
        try json.objectField(key);
        try json.write(@field(entity.uks, key));
    }
    try json.endObject();
    try json.objectField("fks");
    try json.beginObject();
    inline for (@typeInfo(@TypeOf(entity.fks)).@"struct".field_names) |key| {
        try json.objectField(key);
        try json.write(@field(entity.fks, key));
    }
    try json.endObject();
    try json.objectField("fields");
    try json.beginArray();
    inline for (@typeInfo(Row).@"struct".field_names) |field_name| {
        const info = @field(entity.fields, field_name);
        const T = @FieldType(Row, field_name);
        try json.beginObject();
        try json.objectField("name");
        try json.write(field_name);
        try json.objectField("label");
        try json.write(info.label);
        try json.objectField("type");
        try json.write(info.type);
        try json.objectField("is_name");
        try json.write(info.is_name);
        try json.objectField("nullable");
        try json.write(info.nullable);
        try json.objectField("storage");
        try json.write(fieldStorage(T));
        if (@typeInfo(nonOptional(T)) == .@"struct") try writeNestedFields(json, nonOptional(T));
        try json.endObject();
    }
    try json.endArray();
    try json.endObject();
}

fn nonOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |optional| optional.child,
        else => T,
    };
}

/// En objetos anidados la nulabilidad procede de sus tipos Zig, no de otro record.
fn writeNestedFields(json: *std.json.Stringify, comptime T: type) std.json.Stringify.Error!void {
    const info = @typeInfo(T).@"struct";
    try json.objectField("fields");
    try json.beginArray();
    inline for (info.field_names, info.field_types) |name, FieldType| {
        try json.beginObject();
        try json.objectField("name");
        try json.write(name);
        try json.objectField("nullable");
        try json.write(@typeInfo(FieldType) == .optional);
        try json.objectField("storage");
        try json.write(fieldStorage(FieldType));
        if (@typeInfo(nonOptional(FieldType)) == .@"struct") try writeNestedFields(json, nonOptional(FieldType));
        try json.endObject();
    }
    try json.endArray();
}
