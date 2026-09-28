//! Tipos de dominio, campos y records: validación, defaults y tipos de instancia.
//! También compone definiciones con merge. fieldType y selectedType se comparten
//! con el modelo para generar tipos de campo con una sola interpretación de nullable.

const name_lists = @import("names.zig");

/// Tipo de dominio: contiene el tipo Zig usado en las instancias de records.
/// Cada sistema define su colección de tipos extendiendo `common_type_defs`.
pub const TypeDef = struct {
    Type: type,
};

pub const common_type_defs = defineTypes(.{
    .text = TypeDef{ .Type = []const u8 },
    .integer = TypeDef{ .Type = i64 },
    .boolean = TypeDef{ .Type = bool },
});

fn isTypeDefLike(comptime T: type) bool {
    if (T == TypeDef) return true;
    // También se acepta un struct anónimo con la forma exacta de TypeDef,
    // como haría un `satisfies` estructural.
    const info = @typeInfo(T);
    if (info != .@"struct" or info.@"struct".is_tuple) return false;
    if (info.@"struct".field_names.len != 1) return false;
    if (!name_lists.eql(info.@"struct".field_names[0], "Type")) return false;
    return info.@"struct".field_types[0] == type;
}

pub fn checkTypeDefs(comptime type_defs: anytype) void {
    const info = @typeInfo(@TypeOf(type_defs));
    if (info != .@"struct" or info.@"struct".is_tuple)
        @compileError("a type collection must be a struct of TypeDef values");
    inline for (info.@"struct".field_names) |type_name| {
        if (!isTypeDefLike(@TypeOf(@field(type_defs, type_name))))
            @compileError("type '" ++ type_name ++ "': must be a TypeDef (like zigma.TypeDef{ .Type = i64 })");
        if (@typeInfo(@field(type_defs, type_name).Type) == .optional)
            @compileError("type '" ++ type_name ++ "': domain types must be non-optional; use field 'nullable'");
    }
}

/// Comprobación de una colección de tipos en su declaración: verifica que cada
/// campo sea un TypeDef y devuelve la colección sin cambios. Sin ella, una
/// colección mal formada fallaría en su primer uso, lejos del error original.
pub fn defineTypes(comptime type_defs: anytype) @TypeOf(type_defs) {
    comptime checkTypeDefs(type_defs);
    return type_defs;
}

/// El lado Info de la definición de un campo: todo explícito.
pub const FieldInfo = struct {
    type: []const u8,
    is_name: bool,
    nullable: bool,
    label: []const u8,
    description: []const u8,
};

fn checkField(comptime type_defs: anytype, comptime field_def: anytype, comptime field_name: []const u8) void {
    const FieldDefType = @TypeOf(field_def);
    const info = @typeInfo(FieldDefType);
    if (info != .@"struct" or info.@"struct".is_tuple)
        @compileError("field '" ++ field_name ++ "': a field definition must be a struct like .{ .type = \"text\" }");
    if (!@hasField(FieldDefType, "type"))
        @compileError("field '" ++ field_name ++ "': missing 'type'");
    inline for (info.@"struct".field_names) |prop_name| {
        const value = @field(field_def, prop_name);
        const PropType = @TypeOf(value);
        if (name_lists.eql(prop_name, "type")) {
            if (!name_lists.isStringType(PropType))
                @compileError("field '" ++ field_name ++ "': 'type' must be the name of a domain type");
            if (!@hasField(@TypeOf(type_defs), value))
                @compileError("field '" ++ field_name ++ "': unknown type '" ++ value ++ "'");
        } else if (name_lists.eql(prop_name, "is_name")) {
            if (PropType != bool or value != true)
                @compileError("field '" ++ field_name ++ "': is_name only admits true in a definition (false is the default)");
        } else if (name_lists.eql(prop_name, "nullable")) {
            if (PropType != bool)
                @compileError("field '" ++ field_name ++ "': 'nullable' must be a bool");
        } else if (name_lists.eql(prop_name, "label") or name_lists.eql(prop_name, "description")) {
            if (!name_lists.isStringType(PropType))
                @compileError("field '" ++ field_name ++ "': '" ++ prop_name ++ "' must be a string");
        } else {
            @compileError("field '" ++ field_name ++ "': unknown property '" ++ prop_name ++ "'");
        }
    }
}

pub fn checkRecord(comptime type_defs: anytype, comptime rec: anytype) void {
    const info = @typeInfo(@TypeOf(rec));
    if (info != .@"struct" or info.@"struct".is_tuple)
        @compileError("a record definition must be a struct of field definitions");
    inline for (info.@"struct".field_names) |field_name| {
        checkField(type_defs, @field(rec, field_name), field_name);
    }
}

/// El `satisfies` del framework: comprueba que `rec` sea una definición de record
/// bien formada sobre `type_defs` y la devuelve sin cambios, conservando su tipo
/// literal exacto: qué propiedades están presentes en cada definición de campo.
pub fn record(comptime type_defs: anytype, comptime rec: anytype) @TypeOf(rec) {
    comptime checkRecord(type_defs, rec);
    return rec;
}

/// Instancia del record: cada campo recibe T o ?T según su nulabilidad.
/// Se conserva el orden y no se aplican las restricciones de una entidad.
pub fn RecordInstanceType(comptime type_defs: anytype, comptime rec: anytype) type {
    comptime checkTypeDefs(type_defs);
    comptime checkRecord(type_defs, rec);
    return selectedType(type_defs, completeRecord(rec), @typeInfo(@TypeOf(rec)).@"struct".field_names);
}

/// Tipo Info correspondiente al tipo Def de un record: los mismos nombres
/// de campos, cada uno con tipo `FieldInfo`.
pub fn RecordInfoOf(comptime RecordDefType: type) type {
    const rec_names = @typeInfo(RecordDefType).@"struct".field_names;
    var names: [rec_names.len][]const u8 = undefined;
    for (rec_names, 0..) |name, i| names[i] = name;
    const frozen_names = names;
    return @Struct(.auto, null, &frozen_names, &@splat(FieldInfo), &@splat(.{}));
}

fn LabelHolder(comptime name: []const u8) type {
    return struct {
        const label: [name.len]u8 = blk: {
            var out: [name.len]u8 = undefined;
            for (name, 0..) |c, i| out[i] = if (c == '_') ' ' else c;
            break :blk out;
        };
    };
}

fn fieldLabel(comptime field_def: anytype, comptime name: [:0]const u8) []const u8 {
    if (@hasField(@TypeOf(field_def), "label")) return field_def.label;
    return &LabelHolder(name).label;
}

/// Completa la Def de un record en su Info y explicita todos los defaults:
/// is_name: false, nullable: true, description: '', y label derivado del
/// nombre del campo, reemplazando '_' por ' '.
pub fn completeRecord(comptime rec: anytype) RecordInfoOf(@TypeOf(rec)) {
    var result: RecordInfoOf(@TypeOf(rec)) = undefined;
    inline for (@typeInfo(@TypeOf(rec)).@"struct".field_names) |name| {
        const field_def = @field(rec, name);
        const FieldDefType = @TypeOf(field_def);
        @field(result, name) = .{
            .type = field_def.type,
            .is_name = if (@hasField(FieldDefType, "is_name")) field_def.is_name else false,
            .nullable = if (@hasField(FieldDefType, "nullable")) field_def.nullable else true,
            .label = fieldLabel(field_def, name),
            .description = if (@hasField(FieldDefType, "description")) field_def.description else "",
        };
    }
    return result;
}

fn mergedFieldNames(comptime Parts: type) []const [:0]const u8 {
    comptime var names: []const [:0]const u8 = &.{};
    inline for (@typeInfo(Parts).@"struct".field_names) |part_name| {
        const Part = @FieldType(Parts, part_name);
        inline for (@typeInfo(Part).@"struct".field_names) |field_name| {
            if (!name_lists.containsName(names, field_name)) names = names ++ [_][:0]const u8{field_name};
        }
    }
    return names;
}

fn lastPartWith(comptime Parts: type, comptime name: []const u8) [:0]const u8 {
    comptime var result: ?[:0]const u8 = null;
    inline for (@typeInfo(Parts).@"struct".field_names) |part_name| {
        if (@hasField(@FieldType(Parts, part_name), name)) result = part_name;
    }
    return result.?;
}

/// Tipo de `merge(parts)`: nombres de campos en orden de primera aparición.
/// El tipo, y luego el valor, de un campo repetido proviene de la última parte
/// que lo contiene, como el spread de objetos literales en TypeScript.
pub fn Merged(comptime Parts: type) type {
    const names = mergedFieldNames(Parts);
    var types: [names.len]type = undefined;
    for (names, 0..) |name, i| {
        types[i] = @FieldType(@FieldType(Parts, lastPartWith(Parts, name)), name);
    }
    const frozen = types;
    return @Struct(.auto, null, names, &frozen, &@splat(.{}));
}

/// Combina structs (definiciones de records o colecciones de tipos): equivale
/// al spread de TypeScript `{...a, ...b}`. `parts` es una tupla de structs.
pub fn merge(comptime parts: anytype) Merged(@TypeOf(parts)) {
    var result: Merged(@TypeOf(parts)) = undefined;
    inline for (@typeInfo(Merged(@TypeOf(parts))).@"struct".field_names) |name| {
        const part = @field(parts, lastPartWith(@TypeOf(parts), name));
        @field(result, name) = @field(part, name);
    }
    return result;
}

pub fn fieldType(comptime type_defs: anytype, comptime field: FieldInfo) type {
    const T = @field(type_defs, field.type).Type;
    return if (field.nullable) ?T else T;
}

pub fn selectedType(comptime type_defs: anytype, comptime fields: anytype, comptime names: anytype) type {
    var types: [names.len]type = undefined;
    var field_names: [names.len][]const u8 = undefined;
    for (names, 0..) |name, i| {
        field_names[i] = name;
        types[i] = fieldType(type_defs, @field(fields, name));
    }
    const frozen_names = field_names;
    const frozen_types = types;
    return @Struct(.auto, null, &frozen_names, &frozen_types, &@splat(.{}));
}
