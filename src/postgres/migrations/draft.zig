//! Drafts SQL Liquibase: sentencias, bloqueos y verificación de hashes de origen/destino.
//! Devuelve SQL con memoria propia; las herramientas deciden cuándo escribirlo o aplicarlo.

const std = @import("std");
const snapshots = @import("snapshot.zig");
const diff = @import("diff.zig");

// Los bloqueos son comentarios simples por diseño. Este marcador estable permite
// rechazar la aceptación sin interpretar SQL arbitrario editado por el desarrollador.
pub const blocker_marker = "ZIGMA-BLOCKER:";

pub const DraftOptions = struct {
    // Las revisiones intervienen en el orden de Liquibase y en la identidad del changeset.
    revision: u32,
    // Nombre breve legible inferido por las herramientas o indicado explícitamente
    // por el desarrollador; la herramienta de filesystem lo valida antes de generar el SQL.
    name: []const u8,
};

pub const Draft = struct {
    // Bytes propios de SQL con formato Liquibase, listos para escribir en db/drafts.
    sql: []u8,
    // Si se conserva este valor, la aceptación puede rechazar de inmediato sin
    // volver a recorrer el texto; los drafts persistidos se revisan mediante el marcador.
    blocker_count: usize,

    pub fn deinit(self: Draft, allocator: std.mem.Allocator) void {
        allocator.free(self.sql);
    }
};

fn appendQuoted(out: *std.ArrayList(u8), allocator: std.mem.Allocator, identifier: []const u8) !void {
    // La generación del draft en runtime repite el escape de identificadores del
    // generador DDL: los nombres confiables del snapshot se delimitan con comillas
    // y sus comillas internas se duplican.
    try out.append(allocator, '"');
    for (identifier) |byte| {
        try out.append(allocator, byte);
        if (byte == '"') try out.append(allocator, '"');
    }
    try out.append(allocator, '"');
}

fn appendNameList(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    names: []const []const u8,
) !void {
    for (names, 0..) |name, index| {
        if (index != 0) try out.appendSlice(allocator, ", ");
        try appendQuoted(out, allocator, name);
    }
}

fn appendTableColumn(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    column: snapshots.Column,
) !void {
    // `sql_type` es texto confiable de un mapping definido en código; el identificador
    // siempre va entre comillas. La nulabilidad del snapshot ya contempla las PK.
    try appendQuoted(out, allocator, column.name);
    try out.print(allocator, " {s}{s}", .{ column.sql_type, if (column.nullable) "" else " NOT NULL" });
}

fn appendAddKey(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    table_name: []const u8,
    kind: []const u8,
    key: snapshots.Key,
) !void {
    // `kind` es un fragmento controlado por el generador, como UNIQUE;
    // nunca proviene del snapshot ni de una entrada del usuario.
    try out.appendSlice(allocator, "ALTER TABLE ");
    try appendQuoted(out, allocator, table_name);
    try out.appendSlice(allocator, " ADD CONSTRAINT ");
    try appendQuoted(out, allocator, key.name);
    try out.print(allocator, " {s} (", .{kind});
    try appendNameList(out, allocator, key.columns);
    try out.appendSlice(allocator, ");\n");
}

fn appendAddForeignKey(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    table_name: []const u8,
    key: snapshots.ForeignKey,
) !void {
    try out.appendSlice(allocator, "ALTER TABLE ");
    try appendQuoted(out, allocator, table_name);
    try out.appendSlice(allocator, " ADD CONSTRAINT ");
    try appendQuoted(out, allocator, key.name);
    try out.appendSlice(allocator, " FOREIGN KEY (");
    try appendNameList(out, allocator, key.columns);
    try out.appendSlice(allocator, ") REFERENCES ");
    try appendQuoted(out, allocator, key.target_table);
    try out.appendSlice(allocator, " (");
    try appendNameList(out, allocator, key.target_columns);
    try out.appendSlice(allocator, ");\n");
}

fn appendBlocker(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    blocker_count: *usize,
    comptime format: []const u8,
    args: anytype,
) !void {
    // Incrementa antes de formatear para registrar que esta vía requiere intervención
    // incluso mientras el draft está parcialmente construido. El valor se entrega
    // al completar la operación; los errores de formato abortan la generación completa.
    blocker_count.* += 1;
    try out.appendSlice(allocator, "-- ZIGMA-BLOCKER: ");
    try out.print(allocator, format, args);
    try out.appendSlice(allocator, "\n");
}

fn appendCreateTable(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    table: snapshots.Table,
) !void {
    // Las tablas nuevas se emiten sin FKs. Una pasada posterior agrega todas las FKs
    // cuando ya existen sus posibles destinos. Así los drafts no requieren un
    // ordenamiento topológico y admiten ciclos entre tablas.
    try out.appendSlice(allocator, "CREATE TABLE ");
    try appendQuoted(out, allocator, table.name);
    try out.appendSlice(allocator, " (\n");
    for (table.columns, 0..) |column, index| {
        try out.appendSlice(allocator, "    ");
        try appendTableColumn(out, allocator, column);
        // Cada columna lleva coma porque siempre le sigue la PK obligatoria.
        try out.appendSlice(allocator, ",\n");
        _ = index;
    }
    try out.appendSlice(allocator, "    CONSTRAINT ");
    try appendQuoted(out, allocator, table.primary_key.name);
    try out.appendSlice(allocator, " PRIMARY KEY (");
    try appendNameList(out, allocator, table.primary_key.columns);
    try out.append(allocator, ')');
    for (table.unique_keys) |key| {
        try out.appendSlice(allocator, ",\n    CONSTRAINT ");
        try appendQuoted(out, allocator, key.name);
        try out.appendSlice(allocator, " UNIQUE (");
        try appendNameList(out, allocator, key.columns);
        try out.append(allocator, ')');
    }
    try out.appendSlice(allocator, "\n);\n");
}

fn draftDigestMatches(draft_sql: []const u8, marker: []const u8, snapshot: []const u8) bool {
    // Si falta el marcador o está truncado, el draft es inválido; se evita acceder
    // fuera de los límites de un slice o aceptar un historial no verificable.
    const start = (std.mem.indexOf(u8, draft_sql, marker) orelse return false) + marker.len;
    if (draft_sql.len < start + 64) return false;
    const digest = snapshots.snapshotDigest(snapshot);
    return std.mem.eql(u8, draft_sql[start .. start + 64], &digest);
}

/// Es true solo si ambos extremos inmutables registrados en el draft siguen
/// coincidiendo con los snapshots aceptado y deseado recibidos.
pub fn draftMatchesSnapshots(
    draft_sql: []const u8,
    accepted_snapshot: []const u8,
    desired_snapshot: []const u8,
) bool {
    return draftDigestMatches(draft_sql, "from-sha256=", accepted_snapshot) and
        draftDigestMatches(draft_sql, "to-sha256=", desired_snapshot);
}

pub fn draftHasBlockers(draft_sql: []const u8) bool {
    // El desarrollador aprueba un bloqueo reemplazando o quitando su marcador
    // al escribir SQL concreto. Por eso, la aceptación solo necesita una búsqueda estable.
    return std.mem.indexOf(u8, draft_sql, blocker_marker) != null;
}

/// Produce un draft SQL con formato Liquibase. Los bloqueos son comentarios;
/// los drafts deben permanecer fuera del directorio del changelog aceptado hasta
/// que el desarrollador los resuelva y se supere la verificación del catálogo.
pub fn createMigrationDraft(
    allocator: std.mem.Allocator,
    previous_snapshot: []const u8,
    current_snapshot: []const u8,
    options: DraftOptions,
) !Draft {
    // Vuelve a parsear ambos extremos porque generar SQL requiere el detalle
    // completo de los objetos, no solo la lista resumida de Change.
    var previous = try snapshots.parseSnapshot(allocator, previous_snapshot);
    defer previous.deinit();
    var current = try snapshots.parseSnapshot(allocator, current_snapshot);
    defer current.deinit();

    // ArrayList gestiona el draft durante su construcción hasta que `toOwnedSlice`
    // lo transfiere a Draft. `errdefer` cubre todas las salidas anteriores.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var blockers: usize = 0;
    var statement_count: usize = 0;
    // Los hashes vinculan el draft con extremos de origen y destino inmutables.
    // Editar entidades o aceptar otra migración deja este draft desactualizado.
    const from_hash = snapshots.snapshotDigest(previous_snapshot);
    const to_hash = snapshots.snapshotDigest(current_snapshot);

    // Los metadatos SQL de Liquibase aportan una identidad estable de autor/id
    // y conservan los hashes de verificación en un comentario que no se ejecuta.
    try out.appendSlice(allocator, "--liquibase formatted sql\n");
    try out.print(allocator, "--changeset zigma:{d:0>6}_{s}\n", .{ options.revision, options.name });
    try out.print(allocator, "--comment: generated by Zigma; from-sha256={s}; to-sha256={s}\n\n", .{ &from_hash, &to_hash });

    // Los cambios destructivos de restricciones deben resolverse antes que sus columnas.
    // Quitar una tabla es ambiguo con renombrarla y siempre bloquea: la ausencia
    // en el estado deseado nunca permite inferir DROP ni CASCADE.
    for (previous.value.tables) |old_table| {
        const new_table = snapshots.findTable(current.value, old_table.name) orelse continue;
        if (!snapshots.keysEqual(old_table.primary_key, new_table.primary_key))
            try appendBlocker(&out, allocator, &blockers, "primary key of table '{s}' changed; write explicit DROP/ADD CONSTRAINT SQL", .{old_table.name});

        for (old_table.unique_keys) |old_key| {
            const new_key = snapshots.findKey(new_table.unique_keys, old_key.name);
            if (new_key == null or !snapshots.keysEqual(old_key, new_key.?.*))
                try appendBlocker(&out, allocator, &blockers, "unique constraint '{s}' on table '{s}' was removed or changed; approve its removal explicitly", .{ old_key.name, old_table.name });
        }
        for (old_table.foreign_keys) |old_key| {
            const new_key = snapshots.findForeignKey(new_table.foreign_keys, old_key.name);
            if (new_key == null or !snapshots.foreignKeysEqual(old_key, new_key.?.*))
                try appendBlocker(&out, allocator, &blockers, "foreign key '{s}' on table '{s}' was removed or changed; approve its removal explicitly", .{ old_key.name, old_table.name });
        }
    }

    for (previous.value.tables) |old_table| {
        if (snapshots.findTable(current.value, old_table.name) == null)
            try appendBlocker(&out, allocator, &blockers, "table '{s}' was removed; decide whether this is DROP TABLE or a rename", .{old_table.name});
    }

    // Primero crea las tablas nuevas sin FKs; agrega las FKs cuando ya existen todas las
    // tablas.
    for (current.value.tables) |new_table| {
        if (snapshots.findTable(previous.value, new_table.name) == null) {
            try appendCreateTable(&out, allocator, new_table);
            try out.append(allocator, '\n');
            statement_count += 1;
        }
    }

    for (current.value.tables) |new_table| {
        // Las tablas existentes se procesan columna por columna. Los bloqueos de orden
        // suprimen ADD COLUMN automático: agregar al final impediría la igualdad
        // del catálogo incluso si el SQL se ejecutara correctamente.
        const old_table = snapshots.findTable(previous.value, new_table.name) orelse continue;
        const layout_requires_rebuild = diff.columnLayoutRequiresRebuild(old_table.*, new_table);
        if (layout_requires_rebuild)
            try appendBlocker(&out, allocator, &blockers, "existing columns of table '{s}' were reordered; PostgreSQL requires an explicit table rebuild", .{new_table.name});

        for (old_table.columns) |old_column| {
            if (snapshots.findColumn(new_table, old_column.name) == null)
                try appendBlocker(&out, allocator, &blockers, "column '{s}.{s}' was removed; decide whether this is DROP COLUMN or a rename", .{ new_table.name, old_column.name });
        }

        for (new_table.columns) |new_column| {
            const old_column = snapshots.findColumn(old_table.*, new_column.name) orelse {
                if (layout_requires_rebuild) {
                    // ADD COLUMN siempre agrega al final en PostgreSQL: emitirlo
                    // acá nunca produciría el orden de catálogo deseado.
                } else if (!new_column.nullable) {
                    // Las filas existentes requieren completar sus datos según la aplicación
                    // antes de poder imponer NOT NULL.
                    try appendBlocker(&out, allocator, &blockers, "new column '{s}.{s}' is NOT NULL; add it, backfill existing rows, then set NOT NULL explicitly", .{ new_table.name, new_column.name });
                } else {
                    // Agregar columnas nullable al final es el ALTER seguro y directo
                    // que esta fase soporta automáticamente.
                    try out.appendSlice(allocator, "ALTER TABLE ");
                    try appendQuoted(&out, allocator, new_table.name);
                    try out.appendSlice(allocator, " ADD COLUMN ");
                    try appendTableColumn(&out, allocator, new_column);
                    try out.appendSlice(allocator, ";\n\n");
                    statement_count += 1;
                }
                continue;
            };

            if (!std.mem.eql(u8, old_column.sql_type, new_column.sql_type))
                try appendBlocker(&out, allocator, &blockers, "column '{s}.{s}' changed SQL type from '{s}' to '{s}'; provide an explicit USING expression", .{ new_table.name, new_column.name, old_column.sql_type, new_column.sql_type });
            if (old_column.nullable and !new_column.nullable)
                try appendBlocker(&out, allocator, &blockers, "column '{s}.{s}' became NOT NULL; provide validation/backfill SQL first", .{ new_table.name, new_column.name });
            if (!old_column.nullable and new_column.nullable) {
                try out.appendSlice(allocator, "ALTER TABLE ");
                try appendQuoted(&out, allocator, new_table.name);
                try out.appendSlice(allocator, " ALTER COLUMN ");
                try appendQuoted(&out, allocator, new_column.name);
                try out.appendSlice(allocator, " DROP NOT NULL;\n\n");
                statement_count += 1;
            }
            if (!std.mem.eql(u8, old_column.domain_type, new_column.domain_type) and
                std.mem.eql(u8, old_column.sql_type, new_column.sql_type) and
                old_column.nullable == new_column.nullable)
            {
                // Conserva una indicación para la revisión aunque no se necesite
                // un cambio visible para PostgreSQL.
                try out.print(allocator, "-- Zigma domain type metadata changed for {s}.{s}: {s} -> {s}\n", .{ new_table.name, new_column.name, old_column.domain_type, new_column.domain_type });
            }
        }
    }

    // Agrega UKs y FKs nuevas después de terminar las tablas y columnas. Las
    // restricciones modificadas ya se bloquearon y no se reemplazan parcialmente.
    for (current.value.tables) |new_table| {
        const old_table = snapshots.findTable(previous.value, new_table.name);
        if (old_table) |old| {
            if (!snapshots.keysEqual(old.primary_key, new_table.primary_key)) {
                // El bloqueo anterior cubre todo el reemplazo: no se emite un ADD
                // parcial que pueda entrar en conflicto con la restricción anterior.
            }
            for (new_table.unique_keys) |new_key| {
                const old_key = snapshots.findKey(old.unique_keys, new_key.name);
                if (old_key == null) {
                    try appendAddKey(&out, allocator, new_table.name, "UNIQUE", new_key);
                    try out.append(allocator, '\n');
                    statement_count += 1;
                }
            }
            for (new_table.foreign_keys) |new_key| {
                const old_key = snapshots.findForeignKey(old.foreign_keys, new_key.name);
                if (old_key == null) {
                    try appendAddForeignKey(&out, allocator, new_table.name, new_key);
                    try out.append(allocator, '\n');
                    statement_count += 1;
                }
            }
            // Las tablas completamente nuevas ya incluyen sus PK y UK;
            // sus FKs se pospusieron y se agregan todas acá.
        } else {
            for (new_table.foreign_keys) |new_key| {
                try appendAddForeignKey(&out, allocator, new_table.name, new_key);
                try out.append(allocator, '\n');
                statement_count += 1;
            }
        }
    }

    // Los changesets de Liquibase deben contener SQL ejecutable. Un diff solo de
    // metadatos usa una sentencia inocua para poder registrarse exactamente una vez.
    if (statement_count == 0 and blockers == 0)
        try out.appendSlice(allocator, "SELECT 1; -- schema metadata-only change\n");

    // Transfiere la memoria de ArrayList al Draft devuelto;
    // quien llama la libera con Draft.deinit.
    return .{
        .sql = try out.toOwnedSlice(allocator),
        .blocker_count = blockers,
    };
}
