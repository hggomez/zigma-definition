//! Composición del sistema: metadatos normalizados y tipos derivados de entidades.
//! Reutiliza la validación y normalización de records.zig y entities.zig.
//! Row, Patch y Filters consumen la misma información.

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

fn FrameworkInfo(comptime registrations: anytype) type {
    @setEvalBranchQuota(1_000_000);
    const names = @typeInfo(@TypeOf(registrations)).@"struct".field_names;
    var types: [names.len]type = undefined;
    for (names, 0..) |name, i| types[i] = entities.CompletedEntity(@field(registrations, name).definition);
    const frozen = types;
    return @Struct(.auto, null, names, &frozen, &@splat(.{}));
}

/// Interpretación única del contrato. Los tipos Zig quedan en este namespace;
/// `info` contiene solamente metadatos serializables para los consumidores.
pub fn Framework(comptime type_defs: anytype, comptime registrations: anytype) type {
    @setEvalBranchQuota(1_000_000);
    records.checkTypeDefs(type_defs);
    entities.checkRegistrations(registrations);
    for (@typeInfo(@TypeOf(registrations)).@"struct".field_names) |name| {
        const registration = @field(registrations, name);
        if (registration.Type != entities.Entity(type_defs, registration.definition))
            @compileError("entity '" ++ name ++ "': registered Type does not match Entity(type_defs, definition)");
    }
    const Model = struct {
        pub const info: FrameworkInfo(registrations) = blk: {
            @setEvalBranchQuota(1_000_000);
            var result: FrameworkInfo(registrations) = undefined;
            for (@typeInfo(@TypeOf(registrations)).@"struct".field_names) |name| {
                @field(result, name) = entities.completeEntity(@field(registrations, name).definition);
            }
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
            return @field(registrations, checkedEntity(entity)).Type;
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
    };
    // Fuerza la normalización aun cuando todavía no se solicite ningún tipo derivado.
    _ = Model.info;
    return Model;
}
