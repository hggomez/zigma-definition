//! Composición del sistema: metadatos normalizados y tipos derivados de entidades.
//! Reutiliza la validación y normalización de records.zig y entities.zig.
//! Row, Projection, Patch, Filters y RuleInput consumen la misma información.

const std = @import("std");
const records = @import("records.zig");
const entities = @import("entities.zig");
const name_lists = @import("names.zig");

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
    for (names, 0..) |name, i| types[i] = entities.CompletedEntity(entities.defineEntity(@field(entity_defs, name)));
    const frozen = types;
    return @Struct(.auto, null, names, &frozen, &@splat(.{}));
}

/// Interpretación única del contrato. Los tipos Zig quedan en este namespace;
/// `info` contiene solamente metadatos serializables para los consumidores.
pub fn System(comptime type_defs: anytype, comptime entity_defs: anytype) type {
    @setEvalBranchQuota(1_000_000);
    records.checkTypeDefs(type_defs);
    const Model = struct {
        pub const info: SystemInfo(entity_defs) = blk: {
            @setEvalBranchQuota(1_000_000);
            var result: SystemInfo(entity_defs) = undefined;
            for (@typeInfo(@TypeOf(entity_defs)).@"struct".field_names) |name| {
                const entity = entities.defineEntity(@field(entity_defs, name));
                records.checkRecord(type_defs, entity.fields);
                @field(result, name) = entities.completeEntity(entity);
            }
            entities.checkEntities(result);
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
            return records.selectedType(type_defs, fields, @typeInfo(@TypeOf(fields)).@"struct".field_names);
        }

        /// Selección de campos en el orden pedido.
        pub fn Projection(comptime entity: []const u8, comptime names: anytype) type {
            const fields = entityInfo(entity).fields;
            for (names, 0..) |name, i| {
                if (!@hasField(@TypeOf(fields), name))
                    @compileError("entity '" ++ entity ++ "': projection field '" ++ name ++ "' is not a field of the entity");
                for (0..i) |j| {
                    if (name_lists.eql(name, names[j])) @compileError("entity '" ++ entity ++ "': duplicate projection field '" ++ name ++ "'");
                }
            }
            return records.selectedType(type_defs, fields, names);
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
                if (name_lists.containsName(&definition.pk, name)) continue;
                names[i] = name;
                const T = FieldUpdate(records.fieldType(type_defs, @field(definition.fields, name)));
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
