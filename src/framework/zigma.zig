//! zigma-definition: la parte descriptiva del framework SSOTIGAD, en Zig.
//! Las definiciones son valores comptime. Los tipos estáticos (el tipo de instancia
//! de un record y el lado Info de una Def) se derivan de esos valores mediante
//! funciones comptime, de modo que los campos se escriben una sola vez.
//!
//! Convención de nombres heredada del módulo TypeScript system-design:
//! una Def es lo que escribe la persona, solo lo semánticamente necesario;
//! el resto tiene defaults. Una Info es la Def completada con todos los defaults
//! explícitos. La Info de entidades contiene valores simples serializables: los comportamientos
//! especiales se referencian por nombre y se resuelven contra implementaciones registradas
//! aparte.

const std = @import("std");

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
    if (!eql(info.@"struct".field_names[0], "Type")) return false;
    return info.@"struct".field_types[0] == type;
}

fn checkTypeDefs(comptime type_defs: anytype) void {
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

fn eql(comptime a: []const u8, comptime b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn isStringType(comptime T: type) bool {
    switch (@typeInfo(T)) {
        .pointer => |p| switch (p.size) {
            .slice => return p.child == u8,
            .one => switch (@typeInfo(p.child)) {
                .array => |a| return a.child == u8,
                else => return false,
            },
            else => return false,
        },
        else => return false,
    }
}

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
        if (eql(prop_name, "type")) {
            if (!isStringType(PropType))
                @compileError("field '" ++ field_name ++ "': 'type' must be the name of a domain type");
            if (!@hasField(@TypeOf(type_defs), value))
                @compileError("field '" ++ field_name ++ "': unknown type '" ++ value ++ "'");
        } else if (eql(prop_name, "is_name")) {
            if (PropType != bool or value != true)
                @compileError("field '" ++ field_name ++ "': is_name only admits true in a definition (false is the default)");
        } else if (eql(prop_name, "nullable")) {
            if (PropType != bool)
                @compileError("field '" ++ field_name ++ "': 'nullable' must be a bool");
        } else if (eql(prop_name, "label") or eql(prop_name, "description")) {
            if (!isStringType(PropType))
                @compileError("field '" ++ field_name ++ "': '" ++ prop_name ++ "' must be a string");
        } else {
            @compileError("field '" ++ field_name ++ "': unknown property '" ++ prop_name ++ "'");
        }
    }
}

fn checkRecord(comptime type_defs: anytype, comptime rec: anytype) void {
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

fn containsName(comptime names: anytype, comptime name: []const u8) bool {
    for (names) |n| {
        if (eql(n, name)) return true;
    }
    return false;
}

fn mergedFieldNames(comptime Parts: type) []const [:0]const u8 {
    comptime var names: []const [:0]const u8 = &.{};
    inline for (@typeInfo(Parts).@"struct".field_names) |part_name| {
        const Part = @FieldType(Parts, part_name);
        inline for (@typeInfo(Part).@"struct".field_names) |field_name| {
            if (!containsName(names, field_name)) names = names ++ [_][:0]const u8{field_name};
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

fn nameListSlice(comptime list: anytype) []const [:0]const u8 {
    comptime var names: []const [:0]const u8 = &.{};
    comptime var i: usize = 0;
    inline while (i < list.len) : (i += 1) {
        const name: [:0]const u8 = list[i];
        names = names ++ [_][:0]const u8{name};
    }
    return names;
}

fn lenOfListType(comptime T: type) usize {
    return switch (@typeInfo(T)) {
        .array => |a| a.len,
        .@"struct" => |s| if (s.is_tuple) s.field_names.len else @compileError("expected a list of names"),
        else => @compileError("expected a list of names"),
    };
}

fn normalizedPk(comptime pk: anytype) [lenOfListType(@TypeOf(pk))][:0]const u8 {
    var result: [lenOfListType(@TypeOf(pk))][:0]const u8 = undefined;
    comptime var i: usize = 0;
    inline while (i < pk.len) : (i += 1) {
        result[i] = pk[i];
    }
    return result;
}

/// Las FKs referencian la entidad destino POR NOMBRE: un string, no el objeto.
/// Así las definiciones son serializables y se pueden representar FKs circulares
/// y reflexivas. A cambio, el destino solo se puede comprobar a nivel de sistema:
/// ver `defineEntities`.
/// `fields` tiene dos formas: una lista cuando los campos de origen y destino
/// se llaman igual (`.fields = cursos.pk`), o un mapa origen→destino si difieren
/// (`.fields = .{ .jefe = "docente" }`).
fn checkFkDef(comptime fk: anytype, comptime fk_name: []const u8, comptime fields: anytype) void {
    const FkType = @TypeOf(fk);
    const info = @typeInfo(FkType);
    if (info != .@"struct" or info.@"struct".is_tuple)
        @compileError("fk '" ++ fk_name ++ "': a fk definition must be a struct like .{ .entity = ..., .fields = ... }");
    inline for (info.@"struct".field_names) |prop_name| {
        if (!eql(prop_name, "entity") and !eql(prop_name, "fields"))
            @compileError("fk '" ++ fk_name ++ "': unknown property '" ++ prop_name ++ "'");
    }
    if (!@hasField(FkType, "entity") or !@hasField(FkType, "fields"))
        @compileError("fk '" ++ fk_name ++ "' needs 'entity' and 'fields'");
    if (!isStringType(@TypeOf(fk.entity)))
        @compileError("fk '" ++ fk_name ++ "': 'entity' must be the name of the target entity");
    const sources = fkSourceNames(fk);
    for (sources) |source| {
        if (!@hasField(@TypeOf(fields), source))
            @compileError("fk '" ++ fk_name ++ "': source field '" ++ source ++ "' is not a field of the entity");
    }
}

fn checkEntityDef(comptime def: anytype) void {
    const DefType = @TypeOf(def);
    const info = @typeInfo(DefType);
    if (info != .@"struct" or info.@"struct".is_tuple)
        @compileError("an entity definition must be a struct like .{ .pk = ..., .fields = ... }");
    inline for (info.@"struct".field_names) |prop_name| {
        if (!eql(prop_name, "fields") and !eql(prop_name, "pk") and !eql(prop_name, "fks") and !eql(prop_name, "uks") and !eql(prop_name, "rules"))
            @compileError("entity definition: unknown property '" ++ prop_name ++ "'");
    }
    if (!@hasField(DefType, "fields")) @compileError("an entity definition needs 'fields'");
    if (!@hasField(DefType, "pk")) @compileError("an entity definition needs 'pk'");
    if (@hasField(DefType, "rules")) checkRules(def.rules, def.fields);
    const pk_names = nameListSlice(def.pk);
    for (pk_names) |name| {
        if (!@hasField(@TypeOf(def.fields), name))
            @compileError("pk field '" ++ name ++ "' is not a field of the entity");
    }
    if (@hasField(DefType, "uks")) {
        inline for (@typeInfo(@TypeOf(def.uks)).@"struct".field_names) |uk_name| {
            const uk_names = nameListSlice(@field(def.uks, uk_name));
            for (uk_names) |name| {
                if (!@hasField(@TypeOf(def.fields), name))
                    @compileError("uk '" ++ uk_name ++ "': uk field '" ++ name ++ "' is not a field of the entity");
            }
        }
    }
    if (@hasField(DefType, "fks")) {
        inline for (@typeInfo(@TypeOf(def.fks)).@"struct".field_names) |fk_name| {
            checkFkDef(@field(def.fks, fk_name), fk_name, def.fields);
        }
    }
}

fn DefinedEntity(comptime Def: type) type {
    return struct {
        fields: @FieldType(Def, "fields"),
        pk: [lenOfListType(@FieldType(Def, "pk"))][:0]const u8,
        fks: (if (@hasField(Def, "fks")) @FieldType(Def, "fks") else @TypeOf(.{})),
        uks: (if (@hasField(Def, "uks")) @FieldType(Def, "uks") else @TypeOf(.{})),
        rules: (if (@hasField(Def, "rules")) @FieldType(Def, "rules") else @TypeOf(.{})),
    };
}

/// Nivel contenedor: una entidad es la unidad representable como una grilla.
/// Comprueba lo local a la entidad: que PK, UK y campos origen de FK existan
/// en `fields`. `defineEntities` comprueba el destino de las FKs.
/// En runtime es esencialmente la identidad: solo normaliza la PK y
/// completa FKs, UKs y reglas omitidas con colecciones vacías.
pub fn defineEntity(comptime def: anytype) DefinedEntity(@TypeOf(def)) {
    comptime checkEntityDef(def);
    return .{
        .fields = def.fields,
        .pk = normalizedPk(def.pk),
        .fks = if (@hasField(@TypeOf(def), "fks")) def.fks else .{},
        .uks = if (@hasField(@TypeOf(def), "uks")) def.uks else .{},
        .rules = if (@hasField(@TypeOf(def), "rules")) def.rules else .{},
    };
}

fn ExtractedPk(comptime entity: anytype) type {
    var types: [entity.pk.len]type = undefined;
    for (entity.pk, 0..) |name, i| {
        types[i] = @TypeOf(@field(entity.fields, name));
    }
    const frozen = types;
    return @Struct(.auto, null, &entity.pk, &frozen, &@splat(.{}));
}

/// Campos PK de una entidad como definición de record, para heredarlos en otra
/// entidad con `merge`: la repetición semántica útil del documento SSOTIGAD.
/// Ejemplo: `merge(.{ extractPk(cursos), .{ .orden = ... } })`.
pub fn extractPk(comptime entity: anytype) ExtractedPk(entity) {
    var result: ExtractedPk(entity) = undefined;
    inline for (entity.pk) |name| {
        @field(result, name) = @field(entity.fields, name);
    }
    return result;
}

/// Una const a nivel de contenedor siempre se evalúa en scope comptime sin
/// necesitar la palabra clave `comptime`, que sería un error si quien llama
/// ya está en comptime. Así los nombres combinados se pueden usar en ambos contextos.
fn PkMerge(comptime pks: anytype) type {
    return struct {
        const names: []const [:0]const u8 = blk: {
            var seen: []const [:0]const u8 = &.{};
            var pi: usize = 0;
            while (pi < pks.len) : (pi += 1) {
                const pk_list = pks[pi];
                var i: usize = 0;
                while (i < pk_list.len) : (i += 1) {
                    const name: [:0]const u8 = pk_list[i];
                    if (!containsName(seen, name)) seen = seen ++ [_][:0]const u8{name};
                }
            }
            break :blk seen;
        };
    };
}

/// Une PKs que pueden solaparse, sin repetir nombres y conservando el orden
/// de primera aparición. Sirve para PKs combinadas como
/// `mergePk(.{ inscripciones.pk, clases.pk })`; para los campos, `merge`
/// ya elimina por sí mismo las claves duplicadas.
/// Se escribe `PkMerge(pks).names` en vez de usar una función auxiliar: acceder
/// a una declaración es comptime-known incluso en contexto runtime,
/// mientras que una llamada a función equivalente no lo es.
pub fn mergePk(comptime pks: anytype) [PkMerge(pks).names.len][:0]const u8 {
    var result: [PkMerge(pks).names.len][:0]const u8 = undefined;
    inline for (PkMerge(pks).names, 0..) |name, i| {
        result[i] = name;
    }
    return result;
}

fn fkSourceNames(comptime fk: anytype) []const [:0]const u8 {
    const info = @typeInfo(@TypeOf(fk.fields));
    if (info == .@"struct" and !info.@"struct".is_tuple) return info.@"struct".field_names;
    return nameListSlice(fk.fields);
}

/// El mismo recurso que PkMerge: acceder a una declaración hace que los nombres
/// origen sean comptime-known incluso al completar una entidad en contexto runtime.
fn FkSources(comptime fk: anytype) type {
    return struct {
        const names: []const [:0]const u8 = fkSourceNames(fk);
    };
}

fn fkTargetNames(comptime fk: anytype) []const []const u8 {
    const info = @typeInfo(@TypeOf(fk.fields));
    if (info == .@"struct" and !info.@"struct".is_tuple) {
        comptime var names: []const []const u8 = &.{};
        inline for (info.@"struct".field_names) |source| {
            const target: []const u8 = @field(fk.fields, source);
            names = names ++ [_][]const u8{target};
        }
        return names;
    }
    return &NameList(fk.fields).names;
}

fn fkTargetName(comptime fk: anytype, comptime source: [:0]const u8) []const u8 {
    const info = @typeInfo(@TypeOf(fk.fields));
    if (info == .@"struct" and !info.@"struct".is_tuple) return @field(fk.fields, source);
    return source;
}

/// El lado Info de una FK: desaparece la forma abreviada de array;
/// `fields` siempre es el mapa origen→destino.
fn FkInfoOf(comptime fk: anytype) type {
    const sources = fkSourceNames(fk);
    const MapType = @Struct(.auto, null, sources, &@splat([]const u8), &@splat(.{}));
    return struct {
        entity: []const u8,
        fields: MapType,
    };
}

fn CompletedFksType(comptime fks: anytype) type {
    const fk_names_in = @typeInfo(@TypeOf(fks)).@"struct".field_names;
    var fk_names: [fk_names_in.len][]const u8 = undefined;
    for (fk_names_in, 0..) |name, i| fk_names[i] = name;

    var types: [fk_names_in.len]type = undefined;
    inline for (fk_names, 0..) |fk_name, i| {
        types[i] = FkInfoOf(@field(fks, fk_name));
    }
    const frozen_names = fk_names;
    const frozen = types;
    return @Struct(.auto, null, &frozen_names, &frozen, &@splat(.{}));
}

fn completeFks(comptime fks: anytype) CompletedFksType(fks) {
    var result: CompletedFksType(fks) = undefined;
    inline for (@typeInfo(@TypeOf(fks)).@"struct".field_names) |fk_name| {
        const fk = @field(fks, fk_name);
        var fk_info: FkInfoOf(fk) = undefined;
        fk_info.entity = fk.entity;
        inline for (FkSources(fk).names) |source| {
            @field(fk_info.fields, source) = fkTargetName(fk, source);
        }
        @field(result, fk_name) = fk_info;
    }
    return result;
}

fn CompletedEntity(comptime entity: anytype) type {
    return struct {
        fields: RecordInfoOf(@TypeOf(entity.fields)),
        pk: [PkMerge(.{entity.pk}).names.len][:0]const u8,
        fks: CompletedFksType(entity.fks),
        uks: @TypeOf(entity.uks),
        rules: RulesInfo(@TypeOf(entity.rules)),
    };
}

/// El lado Info de una entidad: todo explícito y en una sola forma.
/// Las FKs pierden la forma abreviada de array: `fields` siempre es el mapa
/// origen→destino. La PK queda sin duplicados, por lo que se pueden concatenar
/// PKs solapadas en la Def sin usar `mergePk`. Sus campos quedan no-null
/// sin modificar el record original; las reglas conservan solo sus dependencias.
pub fn completeEntity(comptime entity: anytype) CompletedEntity(entity) {
    var fields = completeRecord(entity.fields);
    inline for (PkMerge(.{entity.pk}).names) |name| @field(fields, name).nullable = false;
    return .{
        .fields = fields,
        .pk = mergePk(.{entity.pk}),
        .fks = completeFks(entity.fks),
        .uks = entity.uks,
        .rules = completeRules(entity.rules),
    };
}

fn sameNameSet(comptime a: anytype, comptime b: anytype) bool {
    if (a.len != b.len) return false;
    for (a) |name| {
        if (!containsName(b, name)) return false;
    }
    return true;
}

fn fkMatchesTargetKey(comptime target_fields: anytype, comptime target: anytype) bool {
    if (sameNameSet(target_fields, PkMerge(.{target.pk}).names)) return true;
    inline for (@typeInfo(@TypeOf(target.uks)).@"struct".field_names) |uk_name| {
        if (sameNameSet(target_fields, nameListSlice(@field(target.uks, uk_name)))) return true;
    }
    return false;
}

fn checkEntities(comptime entity_defs: anytype) void {
    inline for (@typeInfo(@TypeOf(entity_defs)).@"struct".field_names) |entity_name| {
        const entity = @field(entity_defs, entity_name);
        inline for (@typeInfo(@TypeOf(entity.fks)).@"struct".field_names) |fk_name| {
            const fk = @field(entity.fks, fk_name);
            if (!@hasField(@TypeOf(entity_defs), fk.entity))
                @compileError("entity '" ++ entity_name ++ "', fk '" ++ fk_name ++ "': unknown target entity '" ++ fk.entity ++ "'");
            const matches = fkMatchesTargetKey(fkTargetNames(fk), @field(entity_defs, fk.entity));
            if (!matches)
                @compileError("entity '" ++ entity_name ++ "', fk '" ++ fk_name ++ "': target fields do not match the complete pk nor any uk of entity '" ++ fk.entity ++ "'");
        }
    }
}

/// Nivel de sistema, donde se conocen todas las entidades: cada FK debe apuntar
/// a una entidad del sistema y sus campos destino deben ser la PK completa
/// o una de sus UKs. Devuelve las entidades sin cambios.
pub fn defineEntities(comptime entity_defs: anytype) @TypeOf(entity_defs) {
    comptime checkEntities(entity_defs);
    return entity_defs;
}

fn checkRules(comptime rules: anytype, comptime fields: anytype) void {
    const info = @typeInfo(@TypeOf(rules));
    if (info != .@"struct" or (info.@"struct".is_tuple and info.@"struct".field_names.len != 0))
        @compileError("entity definition: 'rules' must be a struct of rule definitions");
    for (info.@"struct".field_names) |name| {
        const rule = @field(rules, name);
        const rule_info = @typeInfo(@TypeOf(rule));
        if (rule_info != .@"struct" or (rule_info.@"struct".is_tuple and rule_info.@"struct".field_names.len != 0))
            @compileError("rule '" ++ name ++ "': must be a struct with a 'fields' list");
        for (rule_info.@"struct".field_names) |property| {
            if (!eql(property, "fields"))
                @compileError("rule '" ++ name ++ "': unknown property '" ++ property ++ "'");
        }
        if (!@hasField(@TypeOf(rule), "fields")) @compileError("rule '" ++ name ++ "': missing 'fields'");
        const list_info = @typeInfo(@TypeOf(rule.fields));
        if (list_info != .array and !(list_info == .@"struct" and (list_info.@"struct".is_tuple or list_info.@"struct".field_names.len == 0)))
            @compileError("rule '" ++ name ++ "': 'fields' must be a list of field names");
        for (rule.fields, 0..) |field, i| {
            if (!isStringType(@TypeOf(field)))
                @compileError("rule '" ++ name ++ "': 'fields' must be a list of field names");
            if (!@hasField(@TypeOf(fields), field))
                @compileError("rule '" ++ name ++ "': field '" ++ field ++ "' is not a field of the entity");
            for (0..i) |j| {
                if (eql(field, rule.fields[j])) @compileError("rule '" ++ name ++ "': duplicate field '" ++ field ++ "'");
            }
        }
    }
}

/// Dependencias serializables; las implementaciones de reglas viven fuera del contrato.
pub const RuleInfo = struct { fields: []const []const u8 };

fn RulesInfo(comptime Rules: type) type {
    return @Struct(.auto, null, @typeInfo(Rules).@"struct".field_names, &@splat(RuleInfo), &@splat(.{}));
}

fn NameList(comptime fields: anytype) type {
    return struct {
        const names: [fields.len][]const u8 = blk: {
            var result: [fields.len][]const u8 = undefined;
            for (fields, 0..) |name, i| result[i] = name;
            break :blk result;
        };
    };
}

fn completeRules(comptime rules: anytype) RulesInfo(@TypeOf(rules)) {
    var result: RulesInfo(@TypeOf(rules)) = undefined;
    inline for (@typeInfo(@TypeOf(rules)).@"struct".field_names) |name| {
        @field(result, name) = .{ .fields = &NameList(@field(rules, name).fields).names };
    }
    return result;
}

fn fieldType(comptime type_defs: anytype, comptime field: FieldInfo) type {
    const T = @field(type_defs, field.type).Type;
    return if (field.nullable) ?T else T;
}

fn selectedType(comptime type_defs: anytype, comptime fields: anytype, comptime names: anytype) type {
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

fn FieldUpdate(comptime T: type) type {
    return union(enum) { unset, set: T };
}

fn DefaultValue(comptime T: type, comptime value: T) type {
    return struct {
        const default: T = value;
    };
}

fn SystemInfo(comptime entity_defs: anytype) type {
    @setEvalBranchQuota(1_000_000);
    const names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;
    var types: [names.len]type = undefined;
    for (names, 0..) |name, i| types[i] = CompletedEntity(defineEntity(@field(entity_defs, name)));
    const frozen = types;
    return @Struct(.auto, null, names, &frozen, &@splat(.{}));
}

/// Interpretación única del contrato. Los tipos Zig quedan en este namespace;
/// `info` contiene solamente metadatos serializables para los consumidores.
pub fn System(comptime type_defs: anytype, comptime entity_defs: anytype) type {
    @setEvalBranchQuota(1_000_000);
    checkTypeDefs(type_defs);
    const Model = struct {
        pub const info: SystemInfo(entity_defs) = blk: {
            @setEvalBranchQuota(1_000_000);
            var result: SystemInfo(entity_defs) = undefined;
            for (@typeInfo(@TypeOf(entity_defs)).@"struct".field_names) |name| {
                const entity = defineEntity(@field(entity_defs, name));
                checkRecord(type_defs, entity.fields);
                @field(result, name) = completeEntity(entity);
            }
            checkEntities(result);
            break :blk result;
        };

        fn entityInfo(comptime entity: []const u8) @FieldType(@TypeOf(info), checkedEntity(entity)) {
            return @field(info, entity);
        }

        fn checkedEntity(comptime entity: []const u8) []const u8 {
            if (!@hasField(@TypeOf(info), entity)) @compileError("system: unknown entity '" ++ entity ++ "'");
            return entity;
        }

        /// Fila completa sin defaults; las PK son obligatorias aunque el record admita null.
        pub fn Row(comptime entity: []const u8) type {
            const fields = entityInfo(entity).fields;
            return selectedType(type_defs, fields, @typeInfo(@TypeOf(fields)).@"struct".field_names);
        }

        /// Selección de campos en el orden pedido.
        pub fn Projection(comptime entity: []const u8, comptime names: anytype) type {
            const fields = entityInfo(entity).fields;
            for (names, 0..) |name, i| {
                if (!@hasField(@TypeOf(fields), name))
                    @compileError("entity '" ++ entity ++ "': projection field '" ++ name ++ "' is not a field of the entity");
                for (0..i) |j| {
                    if (eql(name, names[j])) @compileError("entity '" ++ entity ++ "': duplicate projection field '" ++ name ++ "'");
                }
            }
            return selectedType(type_defs, fields, names);
        }

        /// Modificación parcial: omitir un campo es distinto de asignarle null.
        pub fn Patch(comptime entity: []const u8) type {
            const definition = entityInfo(entity);
            const all_names = @typeInfo(@TypeOf(definition.fields)).@"struct".field_names;
            const count = all_names.len - definition.pk.len;
            var names: [count][]const u8 = undefined;
            var types: [count]type = undefined;
            var attrs: [count]std.lang.Type.Struct.FieldAttributes = undefined;
            var i: usize = 0;
            for (all_names) |name| {
                if (containsName(&definition.pk, name)) continue;
                names[i] = name;
                const T = FieldUpdate(fieldType(type_defs, @field(definition.fields, name)));
                types[i] = T;
                attrs[i] = .{ .default_value_ptr = &DefaultValue(T, .unset).default };
                i += 1;
            }
            const frozen_names = names;
            const frozen_types = types;
            const frozen_attrs = attrs;
            return @Struct(.auto, null, &frozen_names, &frozen_types, &frozen_attrs);
        }

        /// Filtros de igualdad: null significa ausencia del filtro.
        pub fn Filters(comptime entity: []const u8) type {
            const fields = entityInfo(entity).fields;
            const names = @typeInfo(@TypeOf(fields)).@"struct".field_names;
            var types: [names.len]type = undefined;
            var attrs: [names.len]std.lang.Type.Struct.FieldAttributes = undefined;
            for (names, 0..) |name, i| {
                const T = ?@field(type_defs, @field(fields, name).type).Type;
                types[i] = T;
                attrs[i] = .{ .default_value_ptr = &DefaultValue(T, null).default };
            }
            const frozen_types = types;
            const frozen_attrs = attrs;
            return @Struct(.auto, null, names, &frozen_types, &frozen_attrs);
        }

        pub fn RuleInput(comptime entity: []const u8, comptime rule: []const u8) type {
            const rules = entityInfo(entity).rules;
            if (!@hasField(@TypeOf(rules), rule)) @compileError("entity '" ++ entity ++ "': unknown rule '" ++ rule ++ "'");
            return Projection(entity, @field(rules, rule).fields);
        }
    };
    // Dicha asignacion Fuerza la validación aun cuando todavía no se solicite ningún tipo generado.
    _ = Model.info;
    return Model;
}
