//! Snapshot canónico PostgreSQL: tipos, generación comptime, parsing y hashes.
//! Las búsquedas y comparaciones estructurales son compartidas por diff y drafts.
//! No accede a archivos, procesos ni conexiones.

const std = @import("std");
const postgres_ddl = @import("zigma_postgres_ddl");

pub const snapshot_format_version = 1;

// Se serializa el dialecto para que un backend futuro no interprete por accidente
// un snapshot PostgreSQL con la semántica de tipos y restricciones de otro motor.
pub const dialect = "postgresql";

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
    // JSON exige escapar comillas, barras invertidas y controles C0.
    // Los controles sin escape corto usan la forma fija `\u00xx`.
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

pub fn snapshotDigest(bytes: []const u8) [64]u8 {
    // Calcula el hash de los bytes canónicos exactos y codifica los 32 bytes SHA-256
    // como 64 caracteres hexadecimales en minúscula para los metadatos del comentario SQL.
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

// Helpers internos del paquete de migraciones; schema.zig no los reexporta.
pub fn findTable(snapshot: Snapshot, name: []const u8) ?*const Table {
    // Los snapshots son pequeños y ordenados: la búsqueda lineal mantiene simple
    // y determinista el modelo parseado, sin construir mapas hash temporales.
    for (snapshot.tables) |*table| if (eql(table.name, name)) return table;
    return null;
}

pub fn findColumn(table: Table, name: []const u8) ?*const Column {
    for (table.columns) |*column| if (eql(column.name, name)) return column;
    return null;
}

pub fn findKey(keys: []const Key, name: []const u8) ?*const Key {
    for (keys) |*key| if (eql(key.name, name)) return key;
    return null;
}

pub fn findForeignKey(keys: []const ForeignKey, name: []const u8) ?*const ForeignKey {
    for (keys) |*key| if (eql(key.name, name)) return key;
    return null;
}

pub fn namesEqual(a: []const []const u8, b: []const []const u8) bool {
    // La igualdad con orden es esencial: `(a,b)` y `(b,a)` son definiciones
    // PK/FK distintas aunque contengan el mismo conjunto de campos.
    if (a.len != b.len) return false;
    for (a, b) |left, right| if (!eql(left, right)) return false;
    return true;
}

pub fn keysEqual(a: Key, b: Key) bool {
    return eql(a.name, b.name) and namesEqual(a.columns, b.columns);
}

pub fn foreignKeysEqual(a: ForeignKey, b: ForeignKey) bool {
    return eql(a.name, b.name) and
        eql(a.target_table, b.target_table) and
        namesEqual(a.columns, b.columns) and
        namesEqual(a.target_columns, b.target_columns);
}
