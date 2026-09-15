//! Snapshots puros del schema deseado y generación de drafts de migraciones PostgreSQL.
//!
//! Las definiciones actuales de entidades siguen siendo la fuente de verdad del
//! estado deseado. Este módulo serializa solo su estructura visible para PostgreSQL,
//! la compara con el último snapshot aceptado y genera un draft SQL con formato
//! Liquibase. Nunca lee archivos, inicia procesos ni se conecta a una base de datos.

const std = @import("std");
const postgres_ddl = @import("zigma_postgres_ddl");

pub const snapshot_format_version = 1;
// Se serializa el dialecto para que un backend futuro no interprete por accidente
// un snapshot PostgreSQL con la semántica de tipos y restricciones de otro motor.
pub const dialect = "postgresql";
// Los bloqueos son comentarios simples por diseño. Este marcador estable permite
// rechazar la aceptación sin interpretar SQL arbitrario editado por el desarrollador.
pub const blocker_marker = "ZIGMA-BLOCKER:";

/// Representación de una columna JSON canónica con memoria propia en runtime.
/// Conserva el tipo de dominio y el tipo SQL resuelto: uno puede cambiar sin el otro.
pub const Column = struct {
    name: []const u8,
    domain_type: []const u8,
    sql_type: []const u8,
    nullable: bool,
};

/// Modelo compartido de PK y UK: nombre determinista de restricción y columnas
/// ordenadas. El orden importa en claves compuestas y en la equivalencia de catálogo.
pub const Key = struct {
    name: []const u8,
    columns: []const []const u8,
};

/// Las columnas de origen y destino de una FK son listas ordenadas paralelas.
/// Conservar ambas explicita los mappings renombrados y permite serializarlos por separado.
pub const ForeignKey = struct {
    name: []const u8,
    columns: []const []const u8,
    target_table: []const u8,
    target_columns: []const []const u8,
};

/// El modelo de migraciones contiene solo la estructura visible para PostgreSQL.
/// Los labels, descripciones y configuración REST no generan divergencias.
pub const Table = struct {
    name: []const u8,
    columns: []const Column,
    primary_key: Key,
    unique_keys: []const Key,
    foreign_keys: []const ForeignKey,
};

/// Raíz parseada del punto de control versionado del estado deseado.
pub const Snapshot = struct {
    format_version: u32,
    dialect: []const u8,
    tables: []const Table,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn jsonEscape(comptime value: []const u8) []const u8 {
    // El snapshot se crea en comptime: se construye JSON determinista a mano,
    // sin allocator ni dependencia de serialización en runtime.
    comptime var result: []const u8 = "";
    inline for (value) |byte| {
        result = result ++ switch (byte) {
            '"' => "\\\"",
            '\\' => "\\\\",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            0...8, 11, 12, 14...31 => &[_]u8{
                '\\',                          'u',                             '0', '0',
                "0123456789abcdef"[byte >> 4], "0123456789abcdef"[byte & 0x0f],
            },
            else => &[_]u8{byte},
        };
    }
    return comptime result;
}

fn jsonString(comptime value: []const u8) []const u8 {
    return comptime "\"" ++ jsonEscape(value) ++ "\"";
}

fn jsonStringList(comptime values: anytype) []const u8 {
    comptime var result: []const u8 = "[";
    inline for (values, 0..) |value, index| {
        if (index != 0) result = result ++ ",";
        result = result ++ jsonString(value);
    }
    return result ++ "]";
}

fn jsonStructFieldNames(comptime StructType: type) []const u8 {
    return jsonStringList(@typeInfo(StructType).@"struct".field_names);
}

fn jsonStructFieldValues(comptime values: anytype) []const u8 {
    comptime var result: []const u8 = "[";
    inline for (@typeInfo(@TypeOf(values)).@"struct".field_names, 0..) |name, index| {
        if (index != 0) result = result ++ ",";
        result = result ++ jsonString(@field(values, name));
    }
    return result ++ "]";
}

fn renderSnapshot(comptime Model: type, comptime type_mappings: anytype) []const u8 {
    // Los sistemas grandes requieren más ramas del intérprete comptime que el
    // default conservador de Zig; se usa un límite determinista, no ilimitado.
    @setEvalBranchQuota(1_000_000);
    // Reutiliza todas las validaciones de la capa DDL antes de serializar.
    _ = postgres_ddl.createSchemaDdl(Model, type_mappings);
    const model_info = Model.info;

    // La salida es canónica, independiente del formateador: claves en orden fijo,
    // arrays en orden de declaración y sin variaciones irrelevantes de espacios.
    comptime var json: []const u8 =
        "{\n" ++
        "  \"format_version\":1,\n" ++
        "  \"dialect\":\"postgresql\",\n" ++
        "  \"tables\":[\n";

    // El orden de declaración de tablas y columnas forma parte del contrato del
    // snapshot y permite detectar reordenamientos que PostgreSQL no puede expresar.
    inline for (@typeInfo(@TypeOf(model_info)).@"struct".field_names, 0..) |table_name, table_index| {
        const info = @field(model_info, table_name);
        if (table_index != 0) json = json ++ ",\n";
        json = json ++ "    {\"name\":" ++ jsonString(table_name) ++ ",\"columns\":[";

        inline for (@typeInfo(@TypeOf(info.fields)).@"struct".field_names, 0..) |field_name, field_index| {
            const field = @field(info.fields, field_name);
            if (field_index != 0) json = json ++ ",";
            // Model.info ya contiene la nulabilidad efectiva de cada columna.
            json = json ++
                "{\"name\":" ++ jsonString(field_name) ++
                ",\"domain_type\":" ++ jsonString(field.type) ++
                ",\"sql_type\":" ++ jsonString(@field(type_mappings, field.type).sql_type) ++
                ",\"nullable\":" ++ (if (field.nullable) "true" else "false") ++ "}";
        }

        json = json ++ "],\"primary_key\":{\"name\":" ++ jsonString("pk_" ++ table_name) ++
            ",\"columns\":" ++ jsonStringList(info.pk) ++ "},\"unique_keys\":[";

        inline for (@typeInfo(@TypeOf(info.uks)).@"struct".field_names, 0..) |uk_name, uk_index| {
            if (uk_index != 0) json = json ++ ",";
            json = json ++ "{\"name\":" ++ jsonString("uk_" ++ table_name ++ "_" ++ uk_name) ++
                ",\"columns\":" ++ jsonStringList(@field(info.uks, uk_name)) ++ "}";
        }

        json = json ++ "],\"foreign_keys\":[";
        inline for (@typeInfo(@TypeOf(info.fks)).@"struct".field_names, 0..) |fk_name, fk_index| {
            const fk = @field(info.fks, fk_name);
            if (fk_index != 0) json = json ++ ",";
            json = json ++ "{\"name\":" ++ jsonString("fk_" ++ table_name ++ "_" ++ fk_name) ++
                ",\"columns\":" ++ jsonStructFieldNames(@TypeOf(fk.fields)) ++
                ",\"target_table\":" ++ jsonString(fk.entity) ++
                ",\"target_columns\":" ++ jsonStructFieldValues(fk.fields) ++ "}";
        }
        json = json ++ "]}";
    }

    return json ++ "\n  ]\n}\n";
}

/// Devuelve JSON determinista del schema deseado visible para PostgreSQL.
pub fn createSchemaSnapshot(
    comptime Model: type,
    comptime type_mappings: anytype,
) []const u8 {
    // `comptime` en la expresión garantiza que se reciban bytes estáticos
    // inmutables, aptos para comparar con @embedFile y calcular hashes.
    return comptime renderSnapshot(Model, type_mappings);
}

/// Falla la compilación si el schema deseado difiere del snapshot versionado.
/// Un comprobador integrado al build puede mostrar el diff detallado en runtime;
/// esta aserción también protege la compilación directa de la raíz de una aplicación.
pub fn assertAcceptedSnapshot(
    comptime Model: type,
    comptime type_mappings: anytype,
    comptime accepted_snapshot: []const u8,
) void {
    // La igualdad de bytes es estricta porque la serialización canónica garantiza
    // que schemas semánticamente iguales tengan exactamente los mismos bytes.
    const current = comptime createSchemaSnapshot(Model, type_mappings);
    if (comptime !eql(current, accepted_snapshot))
        @compileError("PostgreSQL schema differs from db/schema.snapshot.json; run 'zig build migration'");
}

pub const SnapshotError = error{
    UnsupportedSnapshotVersion,
    UnsupportedDialect,
};

pub fn parseSnapshot(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !std.json.Parsed(Snapshot) {
    // `Parsed` gestiona cada string y slice decodificado mediante el allocator recibido;
    // devolverlo transfiere a quien llama la responsabilidad de ejecutar `deinit`.
    const parsed = try std.json.parseFromSlice(Snapshot, allocator, bytes, .{});
    // Si falla la validación semántica siguiente, libera el árbol ya parseado.
    errdefer parsed.deinit();
    if (parsed.value.format_version != snapshot_format_version)
        return error.UnsupportedSnapshotVersion;
    if (!eql(parsed.value.dialect, dialect))
        return error.UnsupportedDialect;
    return parsed;
}

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

fn findTable(snapshot: Snapshot, name: []const u8) ?*const Table {
    // Los snapshots son pequeños y ordenados: la búsqueda lineal mantiene simple
    // y determinista el modelo parseado, sin construir mapas hash temporales.
    for (snapshot.tables) |*table| if (eql(table.name, name)) return table;
    return null;
}

fn findColumn(table: Table, name: []const u8) ?*const Column {
    for (table.columns) |*column| if (eql(column.name, name)) return column;
    return null;
}

fn findKey(keys: []const Key, name: []const u8) ?*const Key {
    for (keys) |*key| if (eql(key.name, name)) return key;
    return null;
}

fn findForeignKey(keys: []const ForeignKey, name: []const u8) ?*const ForeignKey {
    for (keys) |*key| if (eql(key.name, name)) return key;
    return null;
}

fn namesEqual(a: []const []const u8, b: []const []const u8) bool {
    // La igualdad con orden es esencial: `(a,b)` y `(b,a)` son definiciones
    // PK/FK distintas aunque contengan el mismo conjunto de campos.
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!eql(left, right)) return false;
    return true;
}

fn keysEqual(a: Key, b: Key) bool {
    return eql(a.name, b.name) and namesEqual(a.columns, b.columns);
}

fn foreignKeysEqual(a: ForeignKey, b: ForeignKey) bool {
    return eql(a.name, b.name) and
        eql(a.target_table, b.target_table) and
        namesEqual(a.columns, b.columns) and
        namesEqual(a.target_columns, b.target_columns);
}

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
    var previous = try parseSnapshot(allocator, previous_snapshot);
    defer previous.deinit();
    var current = try parseSnapshot(allocator, current_snapshot);
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
        const new_table = findTable(current.value, old_table.name) orelse {
            try appendChange(&changes, allocator, .table_removed, .blocker, old_table.name, old_table.name);
            continue;
        };

        // Reemplazar una PK es un único bloqueo, no una eliminación y un agregado
        // automáticos separados: cambiar la identidad de los datos requiere aprobación
        // explícita.
        if (!keysEqual(old_table.primary_key, new_table.primary_key))
            try appendChange(&changes, allocator, .primary_key_changed, .blocker, old_table.name, old_table.primary_key.name);

        // Detecta eliminaciones o cambios estructurales con el mismo nombre
        // antes de considerar restricciones nuevas.
        for (old_table.unique_keys) |old_key| {
            const new_key = findKey(new_table.unique_keys, old_key.name);
            if (new_key == null or !keysEqual(old_key, new_key.?.*))
                try appendChange(&changes, allocator, .unique_key_removed_or_changed, .blocker, old_table.name, old_key.name);
        }
        for (old_table.foreign_keys) |old_key| {
            const new_key = findForeignKey(new_table.foreign_keys, old_key.name);
            if (new_key == null or !foreignKeysEqual(old_key, new_key.?.*))
                try appendChange(&changes, allocator, .foreign_key_removed_or_changed, .blocker, old_table.name, old_key.name);
        }

        // PostgreSQL no puede reordenar columnas físicas existentes con ALTER TABLE.
        // Si el orden exacto del catálogo sigue siendo parte del contrato SSOT,
        // la aceptación debe usar una reconstrucción explícita de la tabla.
        if (columnLayoutRequiresRebuild(old_table, new_table.*))
            try appendChange(&changes, allocator, .column_order_changed, .blocker, old_table.name, old_table.name);

        for (old_table.columns) |old_column| {
            const new_column = findColumn(new_table.*, old_column.name) orelse {
                try appendChange(&changes, allocator, .column_removed, .blocker, old_table.name, old_column.name);
                continue;
            };
            // Las conversiones de tipo necesitan una expresión USING elegida por el
            // desarrollador: el estado deseado no expresa cómo convertir los datos.
            if (!eql(old_column.sql_type, new_column.sql_type))
                try appendChange(&changes, allocator, .sql_type_changed, .blocker, old_table.name, old_column.name);
            if (old_column.nullable and !new_column.nullable)
                try appendChange(&changes, allocator, .nullability_tightened, .blocker, old_table.name, old_column.name);
            if (!old_column.nullable and new_column.nullable)
                try appendChange(&changes, allocator, .nullability_relaxed, .automatic, old_table.name, old_column.name);
            if (!eql(old_column.domain_type, new_column.domain_type))
                try appendChange(&changes, allocator, .domain_type_changed, .metadata_only, old_table.name, old_column.name);
        }

        // Una segunda pasada por cada tabla descubre columnas nuevas en el orden deseado.
        for (new_table.columns) |new_column| {
            if (findColumn(old_table, new_column.name) == null)
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
            if (findKey(old_table.unique_keys, new_key.name) == null)
                try appendChange(&changes, allocator, .unique_key_added, .automatic, new_table.name, new_key.name);
        }
        for (new_table.foreign_keys) |new_key| {
            if (findForeignKey(old_table.foreign_keys, new_key.name) == null)
                try appendChange(&changes, allocator, .foreign_key_added, .automatic, new_table.name, new_key.name);
        }
    }

    // Una pasada final por el schema deseado encuentra tablas ausentes del historial.
    // Crear tablas nuevas es seguro porque no puede destruir datos existentes.
    for (current.value.tables) |new_table| {
        if (findTable(previous.value, new_table.name) == null)
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
            if (!eql(first_table, change.table_name)) break false;
        } else true;
        if (one_table)
            try candidate.print(allocator, "update_{s}", .{first_table})
        else
            try candidate.appendSlice(allocator, "update_schema");
    }

    return normalizeMigrationName(allocator, candidate.items);
}

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
    column: Column,
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
    key: Key,
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
    key: ForeignKey,
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
    table: Table,
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

pub fn snapshotDigest(bytes: []const u8) [64]u8 {
    // Calcula el hash de los bytes canónicos exactos y codifica los 32 bytes SHA-256
    // como 64 caracteres hexadecimales en minúscula para los metadatos del comentario SQL.
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn draftDigestMatches(draft_sql: []const u8, marker: []const u8, snapshot: []const u8) bool {
    // Si falta el marcador o está truncado, el draft es inválido; se evita acceder
    // fuera de los límites de un slice o aceptar un historial no verificable.
    const start = (std.mem.indexOf(u8, draft_sql, marker) orelse return false) + marker.len;
    if (draft_sql.len < start + 64) return false;
    const digest = snapshotDigest(snapshot);
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

fn commonColumnOrderChanged(before: Table, after: Table) bool {
    // Registra el último índice deseado encontrado para las columnas históricas.
    // Retroceder indica que cambió su orden relativo, independientemente de los agregados.
    var last_after_index: ?usize = null;
    for (before.columns) |old_column| {
        for (after.columns, 0..) |new_column, new_index| {
            if (!eql(old_column.name, new_column.name)) continue;
            if (last_after_index) |last| if (new_index < last) return true;
            last_after_index = new_index;
            break;
        }
    }
    return false;
}

fn newColumnsAreSuffix(before: Table, after: Table) bool {
    // ADD COLUMN agrega al final en PostgreSQL. Encontrar una columna anterior
    // después de una nueva indica que no se puede lograr el orden físico deseado
    // mediante simples agregados.
    var saw_new = false;
    for (after.columns) |column| {
        if (findColumn(before, column.name) == null) {
            saw_new = true;
        } else if (saw_new) {
            return false;
        }
    }
    return true;
}

fn columnLayoutRequiresRebuild(before: Table, after: Table) bool {
    // Reordenar columnas existentes o insertar una nueva en el medio requiere
    // una reconstrucción explícita según el contrato de orden exacto del catálogo.
    return commonColumnOrderChanged(before, after) or !newColumnsAreSuffix(before, after);
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
    var previous = try parseSnapshot(allocator, previous_snapshot);
    defer previous.deinit();
    var current = try parseSnapshot(allocator, current_snapshot);
    defer current.deinit();

    // ArrayList gestiona el draft durante su construcción hasta que `toOwnedSlice`
    // lo transfiere a Draft. `errdefer` cubre todas las salidas anteriores.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var blockers: usize = 0;
    var statement_count: usize = 0;
    // Los hashes vinculan el draft con extremos de origen y destino inmutables.
    // Editar entidades o aceptar otra migración deja este draft desactualizado.
    const from_hash = snapshotDigest(previous_snapshot);
    const to_hash = snapshotDigest(current_snapshot);

    // Los metadatos SQL de Liquibase aportan una identidad estable de autor/id
    // y conservan los hashes de verificación en un comentario que no se ejecuta.
    try out.appendSlice(allocator, "--liquibase formatted sql\n");
    try out.print(allocator, "--changeset zigma:{d:0>6}_{s}\n", .{ options.revision, options.name });
    try out.print(allocator, "--comment: generated by Zigma; from-sha256={s}; to-sha256={s}\n\n", .{ &from_hash, &to_hash });

    // Los cambios destructivos de restricciones deben resolverse antes que sus columnas.
    // Quitar una tabla es ambiguo con renombrarla y siempre bloquea: la ausencia
    // en el estado deseado nunca permite inferir DROP ni CASCADE.
    for (previous.value.tables) |old_table| {
        const new_table = findTable(current.value, old_table.name) orelse continue;
        if (!keysEqual(old_table.primary_key, new_table.primary_key))
            try appendBlocker(&out, allocator, &blockers, "primary key of table '{s}' changed; write explicit DROP/ADD CONSTRAINT SQL", .{old_table.name});

        for (old_table.unique_keys) |old_key| {
            const new_key = findKey(new_table.unique_keys, old_key.name);
            if (new_key == null or !keysEqual(old_key, new_key.?.*))
                try appendBlocker(&out, allocator, &blockers, "unique constraint '{s}' on table '{s}' was removed or changed; approve its removal explicitly", .{ old_key.name, old_table.name });
        }
        for (old_table.foreign_keys) |old_key| {
            const new_key = findForeignKey(new_table.foreign_keys, old_key.name);
            if (new_key == null or !foreignKeysEqual(old_key, new_key.?.*))
                try appendBlocker(&out, allocator, &blockers, "foreign key '{s}' on table '{s}' was removed or changed; approve its removal explicitly", .{ old_key.name, old_table.name });
        }
    }

    for (previous.value.tables) |old_table| {
        if (findTable(current.value, old_table.name) == null)
            try appendBlocker(&out, allocator, &blockers, "table '{s}' was removed; decide whether this is DROP TABLE or a rename", .{old_table.name});
    }

    // Primero crea las tablas nuevas sin FKs; agrega las FKs cuando ya existen todas las
    // tablas.
    for (current.value.tables) |new_table| {
        if (findTable(previous.value, new_table.name) == null) {
            try appendCreateTable(&out, allocator, new_table);
            try out.append(allocator, '\n');
            statement_count += 1;
        }
    }

    for (current.value.tables) |new_table| {
        // Las tablas existentes se procesan columna por columna. Los bloqueos de orden
        // suprimen ADD COLUMN automático: agregar al final impediría la igualdad
        // del catálogo incluso si el SQL se ejecutara correctamente.
        const old_table = findTable(previous.value, new_table.name) orelse continue;
        const layout_requires_rebuild = columnLayoutRequiresRebuild(old_table.*, new_table);
        if (layout_requires_rebuild)
            try appendBlocker(&out, allocator, &blockers, "existing columns of table '{s}' were reordered; PostgreSQL requires an explicit table rebuild", .{new_table.name});

        for (old_table.columns) |old_column| {
            if (findColumn(new_table, old_column.name) == null)
                try appendBlocker(&out, allocator, &blockers, "column '{s}.{s}' was removed; decide whether this is DROP COLUMN or a rename", .{ new_table.name, old_column.name });
        }

        for (new_table.columns) |new_column| {
            const old_column = findColumn(old_table.*, new_column.name) orelse {
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

            if (!eql(old_column.sql_type, new_column.sql_type))
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
            if (!eql(old_column.domain_type, new_column.domain_type) and
                eql(old_column.sql_type, new_column.sql_type) and
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
        const old_table = findTable(previous.value, new_table.name);
        if (old_table) |old| {
            if (!keysEqual(old.primary_key, new_table.primary_key)) {
                // El bloqueo anterior cubre todo el reemplazo: no se emite un ADD
                // parcial que pueda entrar en conflicto con la restricción anterior.
            }
            for (new_table.unique_keys) |new_key| {
                const old_key = findKey(old.unique_keys, new_key.name);
                if (old_key == null) {
                    try appendAddKey(&out, allocator, new_table.name, "UNIQUE", new_key);
                    try out.append(allocator, '\n');
                    statement_count += 1;
                }
            }
            for (new_table.foreign_keys) |new_key| {
                const old_key = findForeignKey(old.foreign_keys, new_key.name);
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
// JSON exige escapar comillas, barras invertidas y caracteres de control comunes;
// los demás controles C0 usan la forma fija `\u00xx`.
// Cada `errdefer` cubre solo las reservas completadas hasta ese punto y evita
// fugas si falla una duplicación o un crecimiento posterior de la lista.
// Permitir null no puede invalidar filas existentes y es seguro; prohibirlo
// puede requerir validación o completar datos y por eso bloquea.
// Los cambios solo de dominio se registran para hacerlos visibles, pero no requieren
// SQL si el tipo SQL resuelto y la nulabilidad siguen siendo iguales.
// Cada columna lleva una coma después porque siempre le sigue
// la restricción PK obligatoria.
