//! zigma-definition: the descriptive part of the SSOTIGAD framework, in Zig.
//! Definitions are comptime values; the static types (the record instance
//! type, the Info side of a Def) are derived from those values with comptime
//! functions, so the fields are written only once.
//!
//! Naming convention (inherited from the TypeScript system-design module):
//! a Def is what the human writes (only what is semantically needed, the
//! rest has defaults); an Info is the Def completed with every default made
//! explicit. Both are plain serializable values: special behaviors are
//! referenced by name and resolved against implementations registered apart.

const std = @import("std");

/// A domain type: carries the Zig type used in record instances.
/// Each system defines its own type collection extending `common_type_defs`.
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
    // an anonymous struct with exactly the shape of TypeDef is also accepted,
    // like a structural `satisfies` would
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
    }
}

/// The declaration-site check of a type collection: checks that every field
/// is a TypeDef and returns the collection unchanged. Without it, a malformed
/// collection would only fail where it is first used, far from the mistake.
pub fn defineTypes(comptime type_defs: anytype) @TypeOf(type_defs) {
    comptime checkTypeDefs(type_defs);
    return type_defs;
}

/// The Info side of a field definition: everything explicit.
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

/// The `satisfies` of the framework: checks that `rec` is a well formed
/// record definition over `type_defs` and returns it unchanged, keeping its
/// exact literal type (which properties are present in each field def).
pub fn record(comptime type_defs: anytype, comptime rec: anytype) @TypeOf(rec) {
    comptime checkRecord(type_defs, rec);
    return rec;
}

/// The type of a row of the record: each field gets the Zig type of its
/// domain type. Field order is preserved.
pub fn RecordInstanceType(comptime type_defs: anytype, comptime rec: anytype) type {
    comptime checkRecord(type_defs, rec);
    const rec_names = @typeInfo(@TypeOf(rec)).@"struct".field_names;
    var types: [rec_names.len]type = undefined;
    var names: [rec_names.len][]const u8 = undefined;
    for (rec_names, 0..) |name, i| {
        names[i] = name;
        types[i] = @field(type_defs, @field(rec, name).type).Type;
    }
    const frozen_names = names;
    const frozen = types;
    return @Struct(.auto, null, &frozen_names, &frozen, &@splat(.{}));
}

/// The Info type corresponding to a record Def type: same field names, every
/// field a `FieldInfo`.
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

/// Completes a record Def into its Info: every default made explicit
/// (is_name: false, nullable: true, description: '', label derived from the
/// field name replacing '_' with ' ').
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

fn containsName(comptime names: []const [:0]const u8, comptime name: []const u8) bool {
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

/// The type of `merge(parts)`: field names in first-appearance order, the
/// type (and later the value) of a repeated field comes from the last part
/// that has it, like the spread of object literals in TypeScript.
pub fn Merged(comptime Parts: type) type {
    const names = mergedFieldNames(Parts);
    var types: [names.len]type = undefined;
    for (names, 0..) |name, i| {
        types[i] = @FieldType(@FieldType(Parts, lastPartWith(Parts, name)), name);
    }
    const frozen = types;
    return @Struct(.auto, null, names, &frozen, &@splat(.{}));
}

/// Merges structs (record defs, type collections): the equivalent of the
/// TypeScript spread `{...a, ...b}`. `parts` is a tuple of structs.
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

/// fks reference the target entity BY NAME (a string, not the object): that
/// keeps the defs serializable and makes circular and reflexive fks
/// representable. The counterpart is that the target side can only be checked
/// at the system level: see `defineEntities`.
/// `fields` has two forms: a list of names when source and target fields are
/// named the same (`.fields = cursos.pk`), or a source→target map when not
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
        if (!eql(prop_name, "fields") and !eql(prop_name, "pk") and !eql(prop_name, "fks") and !eql(prop_name, "uks"))
            @compileError("entity definition: unknown property '" ++ prop_name ++ "'");
    }
    if (!@hasField(DefType, "fields")) @compileError("an entity definition needs 'fields'");
    if (!@hasField(DefType, "pk")) @compileError("an entity definition needs 'pk'");
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
    };
}

/// The container level: an entity is the unit representable as a grid.
/// Checks what is local to the entity (pk, uk and fk source fields exist in
/// `fields`); the target side of the fks is checked by `defineEntities`.
/// At runtime it is essentially the identity: it only normalizes the pk and
/// defaults fks and uks to empty.
pub fn defineEntity(comptime def: anytype) DefinedEntity(@TypeOf(def)) {
    comptime checkEntityDef(def);
    return .{
        .fields = def.fields,
        .pk = normalizedPk(def.pk),
        .fks = if (@hasField(@TypeOf(def), "fks")) def.fks else .{},
        .uks = if (@hasField(@TypeOf(def), "uks")) def.uks else .{},
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

/// The pk fields of an entity as a record def, to inherit them into another
/// entity with `merge` (the good semantic repetition of the SSOTIGAD
/// document): `merge(.{ extractPk(cursos), .{ .orden = ... } })`.
pub fn extractPk(comptime entity: anytype) ExtractedPk(entity) {
    var result: ExtractedPk(entity) = undefined;
    inline for (entity.pk) |name| {
        @field(result, name) = @field(entity.fields, name);
    }
    return result;
}

/// A container-level const is always evaluated in a comptime scope, without
/// needing the `comptime` keyword (which would be an error when the caller is
/// already comptime); this makes the merged names usable from both contexts.
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

/// Joins pks that may overlap, without repeating names, preserving the order
/// of first appearance. For combined pks like
/// `mergePk(.{ inscripciones.pk, clases.pk })`; for the fields the `merge`
/// already dedups keys by itself.
/// (`PkMerge(pks).names` is spelled instead of taking it through a helper
/// function: a decl access is comptime-known in a runtime context too, which
/// an equivalent function call is not.)
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

/// Same trick as PkMerge: a decl access to make the source names
/// comptime-known also when completing an entity in a runtime context.
fn FkSources(comptime fk: anytype) type {
    return struct {
        const names: []const [:0]const u8 = fkSourceNames(fk);
    };
}

fn fkTargetNames(comptime fk: anytype) []const [:0]const u8 {
    const info = @typeInfo(@TypeOf(fk.fields));
    if (info == .@"struct" and !info.@"struct".is_tuple) {
        comptime var names: []const [:0]const u8 = &.{};
        inline for (info.@"struct".field_names) |source| {
            const target: [:0]const u8 = @field(fk.fields, source);
            names = names ++ [_][:0]const u8{target};
        }
        return names;
    }
    return nameListSlice(fk.fields);
}

fn fkTargetName(comptime fk: anytype, comptime source: [:0]const u8) []const u8 {
    const info = @typeInfo(@TypeOf(fk.fields));
    if (info == .@"struct" and !info.@"struct".is_tuple) return @field(fk.fields, source);
    return source;
}

/// The Info side of a fk: the array shorthand is gone, `fields` is always
/// the source→target map.
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
    };
}

/// The Info side of an entity: everything explicit, and in only one form.
/// The fks lose the array shorthand: `fields` is always the source→target
/// map. The pk is deduplicated, so overlapping pks can be concatenated in the
/// Def without `mergePk`.
pub fn completeEntity(comptime entity: anytype) CompletedEntity(entity) {
    return .{
        .fields = completeRecord(entity.fields),
        .pk = mergePk(.{entity.pk}),
        .fks = completeFks(entity.fks),
        .uks = entity.uks,
    };
}

fn sameNameSet(comptime a: []const [:0]const u8, comptime b: []const [:0]const u8) bool {
    if (a.len != b.len) return false;
    for (a) |name| {
        if (!containsName(b, name)) return false;
    }
    return true;
}

fn fkMatchesTargetKey(comptime target_fields: []const [:0]const u8, comptime target: anytype) bool {
    if (sameNameSet(target_fields, &target.pk)) return true;
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

/// The system level, where all the entities are known: every fk must point
/// to an entity of the system, and its target fields must be the complete pk
/// or one of the uks of it. Returns the entities unchanged.
pub fn defineEntities(comptime entity_defs: anytype) @TypeOf(entity_defs) {
    comptime checkEntities(entity_defs);
    return entity_defs;
}
