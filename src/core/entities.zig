//! Entidades: claves, relaciones y dependencias declaradas de reglas.
//! Comprueba referencias y normaliza la entidad sin modificar su record original.
//! La normalización de campos se delega a records.zig.

const records = @import("records.zig");
const name_lists = @import("names.zig");

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
        if (!name_lists.eql(prop_name, "entity") and !name_lists.eql(prop_name, "fields"))
            @compileError("fk '" ++ fk_name ++ "': unknown property '" ++ prop_name ++ "'");
    }
    if (!@hasField(FkType, "entity") or !@hasField(FkType, "fields"))
        @compileError("fk '" ++ fk_name ++ "' needs 'entity' and 'fields'");
    if (!name_lists.isStringType(@TypeOf(fk.entity)))
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
        if (!name_lists.eql(prop_name, "fields") and !name_lists.eql(prop_name, "pk") and !name_lists.eql(prop_name, "fks") and !name_lists.eql(prop_name, "uks") and !name_lists.eql(prop_name, "rules"))
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
                    if (!name_lists.containsName(seen, name)) seen = seen ++ [_][:0]const u8{name};
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

pub fn CompletedEntity(comptime entity: anytype) type {
    return struct {
        fields: records.RecordInfoOf(@TypeOf(entity.fields)),
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
    var fields = records.completeRecord(entity.fields);
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
        if (!name_lists.containsName(b, name)) return false;
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

pub fn checkEntities(comptime entity_defs: anytype) void {
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
            if (!name_lists.eql(property, "fields"))
                @compileError("rule '" ++ name ++ "': unknown property '" ++ property ++ "'");
        }
        if (!@hasField(@TypeOf(rule), "fields")) @compileError("rule '" ++ name ++ "': missing 'fields'");
        const list_info = @typeInfo(@TypeOf(rule.fields));
        if (list_info != .array and !(list_info == .@"struct" and (list_info.@"struct".is_tuple or list_info.@"struct".field_names.len == 0)))
            @compileError("rule '" ++ name ++ "': 'fields' must be a list of field names");
        for (rule.fields, 0..) |field, i| {
            if (!name_lists.isStringType(@TypeOf(field)))
                @compileError("rule '" ++ name ++ "': 'fields' must be a list of field names");
            if (!@hasField(@TypeOf(fields), field))
                @compileError("rule '" ++ name ++ "': field '" ++ field ++ "' is not a field of the entity");
            for (0..i) |j| {
                if (name_lists.eql(field, rule.fields[j])) @compileError("rule '" ++ name ++ "': duplicate field '" ++ field ++ "'");
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
