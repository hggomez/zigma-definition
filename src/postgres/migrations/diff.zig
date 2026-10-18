//! Diferencias estructurales entre snapshots y nombres de migración deterministas.
//! Clasifica cambios y conserva su orden; no genera SQL ni accede al entorno.

const std = @import("std");
const snapshots = @import("snapshot.zig");

/// Clasificación procesable de una diferencia estructural. Los consumidores pueden
/// construir su propia interfaz o política sobre esta lista sin parsear el draft
/// SQL ni sus comentarios.
pub const ChangeKind = enum {
    table_added,
    table_removed,
    column_added_nullable,
    column_added_not_null,
    column_removed,
    column_order_changed,
    sql_type_changed,
    nullability_relaxed,
    nullability_tightened,
    domain_type_changed,
    primary_key_changed,
    unique_key_added,
    unique_key_removed_or_changed,
    foreign_key_added,
    foreign_key_removed_or_changed,
};

pub const ChangeSafety = enum {
    // Se puede proponer SQL sin conocer los valores de filas existentes ni la intención.
    automatic,
    // Se necesita SQL o aprobación humana antes de verificar el catálogo.
    blocker,
    // La estructura PostgreSQL no cambió, aunque sí el significado del dominio.
    metadata_only,
};

pub const Change = struct {
    kind: ChangeKind,
    safety: ChangeSafety,
    table_name: []u8,
    object_name: []u8,
};

pub const SchemaDiff = struct {
    // Guarda el allocator junto a los cambios que gestiona para impedir
    // que deinit se llame con otro allocator.
    allocator: std.mem.Allocator,
    changes: []Change,

    pub fn deinit(self: SchemaDiff) void {
        for (self.changes) |change| {
            self.allocator.free(change.table_name);
            self.allocator.free(change.object_name);
        }
        self.allocator.free(self.changes);
    }
};

fn appendChange(
    changes: *std.ArrayList(Change),
    allocator: std.mem.Allocator,
    kind: ChangeKind,
    safety: ChangeSafety,
    table_name: []const u8,
    object_name: []const u8,
) !void {
    // Los snapshots parseados se liberan antes que el diff devuelto: se copian
    // los nombres descriptivos a memoria propia independiente.
    const owned_table = try allocator.dupe(u8, table_name);
    errdefer allocator.free(owned_table);
    const owned_object = try allocator.dupe(u8, object_name);
    errdefer allocator.free(owned_object);
    try changes.append(allocator, .{
        .kind = kind,
        .safety = safety,
        .table_name = owned_table,
        .object_name = owned_object,
    });
}

/// Parsea dos snapshots y devuelve todas las diferencias estructurales visibles
/// para PostgreSQL, en orden determinista de tablas y objetos.
pub fn diffSnapshots(
    allocator: std.mem.Allocator,
    previous_snapshot: []const u8,
    current_snapshot: []const u8,
) !SchemaDiff {
    // Parsea por separado para mantener disponibles ambos árboles durante la comparación.
    var previous = try snapshots.parseSnapshot(allocator, previous_snapshot);
    defer previous.deinit();
    var current = try snapshots.parseSnapshot(allocator, current_snapshot);
    defer current.deinit();

    // Ante un fallo parcial, libera a mano los strings propios de Change antes
    // del almacenamiento de ArrayList. Un retorno exitoso transfiere su responsabilidad.
    var changes: std.ArrayList(Change) = .empty;
    errdefer {
        for (changes.items) |change| {
            allocator.free(change.table_name);
            allocator.free(change.object_name);
        }
        changes.deinit(allocator);
    }

    // Primero recorre el schema anterior. Así informa eliminaciones y modificaciones
    // en el orden de declaración histórico.
    for (previous.value.tables) |old_table| {
        const new_table = snapshots.findTable(current.value, old_table.name) orelse {
            try appendChange(&changes, allocator, .table_removed, .blocker, old_table.name, old_table.name);
            continue;
        };

        // Reemplazar una PK es un único bloqueo, no una eliminación y un agregado
        // automáticos separados: cambiar la identidad de los datos requiere aprobación
        // explícita.
        if (!snapshots.keysEqual(old_table.primary_key, new_table.primary_key))
            try appendChange(&changes, allocator, .primary_key_changed, .blocker, old_table.name, old_table.primary_key.name);

        // Detecta eliminaciones o cambios estructurales con el mismo nombre
        // antes de considerar restricciones nuevas.
        for (old_table.unique_keys) |old_key| {
            const new_key = snapshots.findKey(new_table.unique_keys, old_key.name);
            if (new_key == null or !snapshots.keysEqual(old_key, new_key.?.*))
                try appendChange(&changes, allocator, .unique_key_removed_or_changed, .blocker, old_table.name, old_key.name);
        }
        for (old_table.foreign_keys) |old_key| {
            const new_key = snapshots.findForeignKey(new_table.foreign_keys, old_key.name);
            if (new_key == null or !snapshots.foreignKeysEqual(old_key, new_key.?.*))
                try appendChange(&changes, allocator, .foreign_key_removed_or_changed, .blocker, old_table.name, old_key.name);
        }

        // PostgreSQL no puede reordenar columnas físicas existentes con ALTER TABLE.
        // Si el orden exacto del catálogo sigue siendo parte del contrato SSOT,
        // la aceptación debe usar una reconstrucción explícita de la tabla.
        if (columnLayoutRequiresRebuild(old_table, new_table.*))
            try appendChange(&changes, allocator, .column_order_changed, .blocker, old_table.name, old_table.name);

        for (old_table.columns) |old_column| {
            const new_column = snapshots.findColumn(new_table.*, old_column.name) orelse {
                try appendChange(&changes, allocator, .column_removed, .blocker, old_table.name, old_column.name);
                continue;
            };
            // Las conversiones de tipo necesitan una expresión USING elegida por el
            // desarrollador: el estado deseado no expresa cómo convertir los datos.
            if (!std.mem.eql(u8, old_column.sql_type, new_column.sql_type))
                try appendChange(&changes, allocator, .sql_type_changed, .blocker, old_table.name, old_column.name);
            if (old_column.nullable and !new_column.nullable)
                try appendChange(&changes, allocator, .nullability_tightened, .blocker, old_table.name, old_column.name);
            if (!old_column.nullable and new_column.nullable)
                try appendChange(&changes, allocator, .nullability_relaxed, .automatic, old_table.name, old_column.name);
            if (!std.mem.eql(u8, old_column.domain_type, new_column.domain_type))
                try appendChange(&changes, allocator, .domain_type_changed, .metadata_only, old_table.name, old_column.name);
        }

        // Una segunda pasada por cada tabla descubre columnas nuevas en el orden deseado.
        for (new_table.columns) |new_column| {
            if (snapshots.findColumn(old_table, new_column.name) == null)
                try appendChange(
                    &changes,
                    allocator,
                    if (new_column.nullable) .column_added_nullable else .column_added_not_null,
                    if (new_column.nullable) .automatic else .blocker,
                    new_table.name,
                    new_column.name,
                );
        }
        for (new_table.unique_keys) |new_key| {
            if (snapshots.findKey(old_table.unique_keys, new_key.name) == null)
                try appendChange(&changes, allocator, .unique_key_added, .automatic, new_table.name, new_key.name);
        }
        for (new_table.foreign_keys) |new_key| {
            if (snapshots.findForeignKey(old_table.foreign_keys, new_key.name) == null)
                try appendChange(&changes, allocator, .foreign_key_added, .automatic, new_table.name, new_key.name);
        }
    }

    // Una pasada final por el schema deseado encuentra tablas ausentes del historial.
    // Crear tablas nuevas es seguro porque no puede destruir datos existentes.
    for (current.value.tables) |new_table| {
        if (snapshots.findTable(previous.value, new_table.name) == null)
            try appendChange(&changes, allocator, .table_added, .automatic, new_table.name, new_table.name);
    }

    return .{ .allocator = allocator, .changes = try changes.toOwnedSlice(allocator) };
}

fn appendSingleChangeName(
    candidate: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    change: Change,
) !void {
    switch (change.kind) {
        .table_added => try candidate.print(allocator, "create_table_{s}", .{change.table_name}),
        .table_removed => try candidate.print(allocator, "remove_table_{s}", .{change.table_name}),
        .column_added_nullable, .column_added_not_null => try candidate.print(allocator, "add_{s}_{s}", .{ change.table_name, change.object_name }),
        .column_removed => try candidate.print(allocator, "remove_{s}_{s}", .{ change.table_name, change.object_name }),
        .column_order_changed => try candidate.print(allocator, "reorder_{s}_columns", .{change.table_name}),
        .sql_type_changed => try candidate.print(allocator, "change_{s}_{s}_type", .{ change.table_name, change.object_name }),
        .nullability_relaxed => try candidate.print(allocator, "make_{s}_{s}_nullable", .{ change.table_name, change.object_name }),
        .nullability_tightened => try candidate.print(allocator, "make_{s}_{s}_not_null", .{ change.table_name, change.object_name }),
        .domain_type_changed => try candidate.print(allocator, "change_{s}_{s}_domain", .{ change.table_name, change.object_name }),
        .primary_key_changed => try candidate.print(allocator, "change_{s}_primary_key", .{change.table_name}),
        .unique_key_added, .foreign_key_added => try candidate.print(allocator, "add_{s}", .{change.object_name}),
        .unique_key_removed_or_changed, .foreign_key_removed_or_changed => try candidate.print(allocator, "change_{s}", .{change.object_name}),
    }
}

fn normalizeMigrationName(
    allocator: std.mem.Allocator,
    candidate: []const u8,
) ![]u8 {
    var normalized: std.ArrayList(u8) = .empty;
    errdefer normalized.deinit(allocator);
    var separator_pending = false;

    for (candidate) |byte| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (separator_pending and normalized.items.len != 0)
                try normalized.append(allocator, '_');
            try normalized.append(allocator, std.ascii.toLower(byte));
            separator_pending = false;
        } else {
            // Uno o más bytes de puntuación o no ASCII se convierten en un único separador.
            separator_pending = true;
        }
    }

    // Cada candidato generado empieza con un prefijo ASCII fijo de operación.
    // La normalización no puede producir un nombre vacío, aun con identificadores simbólicos.
    std.debug.assert(normalized.items.len != 0);
    return normalized.toOwnedSlice(allocator);
}

/// Infiere un nombre determinista y válido para el filesystem a partir de los
/// cambios estructurales entre snapshots canónicos. Quien llama debe liberar los bytes.
pub fn inferMigrationName(
    allocator: std.mem.Allocator,
    previous_snapshot: []const u8,
    current_snapshot: []const u8,
) ![]u8 {
    const diff = try diffSnapshots(allocator, previous_snapshot, current_snapshot);
    defer diff.deinit();
    if (diff.changes.len == 0) return error.SchemaUnchanged;

    var candidate: std.ArrayList(u8) = .empty;
    defer candidate.deinit(allocator);

    if (diff.changes.len == 1) {
        try appendSingleChangeName(&candidate, allocator, diff.changes[0]);
    } else {
        const first_table = diff.changes[0].table_name;
        const one_table = for (diff.changes[1..]) |change| {
            if (!std.mem.eql(u8, first_table, change.table_name)) break false;
        } else true;
        if (one_table)
            try candidate.print(allocator, "update_{s}", .{first_table})
        else
            try candidate.appendSlice(allocator, "update_schema");
    }

    return normalizeMigrationName(allocator, candidate.items);
}

fn commonColumnOrderChanged(before: snapshots.Table, after: snapshots.Table) bool {
    // Registra el último índice deseado encontrado para las columnas históricas.
    // Retroceder indica que cambió su orden relativo, independientemente de los agregados.
    var last_after_index: ?usize = null;
    for (before.columns) |old_column| {
        for (after.columns, 0..) |new_column, new_index| {
            if (!std.mem.eql(u8, old_column.name, new_column.name)) continue;
            if (last_after_index) |last| if (new_index < last) return true;
            last_after_index = new_index;
            break;
        }
    }
    return false;
}

fn newColumnsAreSuffix(before: snapshots.Table, after: snapshots.Table) bool {
    // ADD COLUMN agrega al final en PostgreSQL. Encontrar una columna anterior
    // después de una nueva indica que no se puede lograr el orden físico deseado
    // mediante simples agregados.
    var saw_new = false;
    for (after.columns) |column| {
        if (snapshots.findColumn(before, column.name) == null) {
            saw_new = true;
        } else if (saw_new) {
            return false;
        }
    }
    return true;
}

// Compartido con draft.zig; no forma parte de la API pública de schema.zig.
pub fn columnLayoutRequiresRebuild(before: snapshots.Table, after: snapshots.Table) bool {
    // Reordenar columnas existentes o insertar una nueva en el medio requiere
    // una reconstrucción explícita según el contrato de orden exacto del catálogo.
    return commonColumnOrderChanged(before, after) or !newColumnsAreSuffix(before, after);
}
