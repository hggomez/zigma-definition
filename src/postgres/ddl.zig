//! Generación pura de DDL PostgreSQL en comptime para definiciones de sistemas zigma.
//! Este módulo solo genera sentencias CREATE TABLE completas. No se conecta
//! a una base, no inspecciona un schema existente ni genera migraciones.

const std = @import("std");

// PostgreSQL guarda los identificadores en un valor `name` con un límite útil de
// 63 bytes. Comprobar la longitud en comptime evita que PostgreSQL trunque en
// silencio dos nombres generados distintos y los convierta en el mismo identificador.
const max_identifier_bytes = 63;

/// Representación PostgreSQL de un tipo de dominio. Se mantiene separada de
/// `zigma.TypeDef` para que el sistema descriptivo no dependa de la base de datos.
pub const TypeMapping = struct {
    sql_type: []const u8,
};

/// Mappings PostgreSQL para los tipos de dominio incorporados en zigma.
pub const common_type_mappings = defineTypeMappings(.{
    .text = TypeMapping{ .sql_type = "TEXT" },
    .integer = TypeMapping{ .sql_type = "BIGINT" },
    .boolean = TypeMapping{ .sql_type = "BOOLEAN" },
});

fn eql(comptime a: []const u8, comptime b: []const u8) bool {
    // En este módulo, ambos operandos son strings comptime. Este wrapper pequeño
    // expresa mejor la intención en las llamadas que manipulan nombres.
    return std.mem.eql(u8, a, b);
}

fn isStringType(comptime T: type) bool {
    // Los literales del schema pueden llegar como slice (`[]const u8`) o como puntero
    // al array de un literal de string (`*const [N:0]u8`). La reflexión acepta ambas
    // formas y rechaza punteros ajenos y valores escalares.
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (pointer.size) {
            .slice => pointer.child == u8,
            .one => switch (@typeInfo(pointer.child)) {
                .array => |array| array.child == u8,
                else => false,
            },
            else => false,
        },
        else => false,
    };
}

fn checkTypeMapping(comptime mapping: anytype, comptime name: []const u8) void {
    // Conserva el tipo literal anónimo recibido, pero inspecciona su estructura
    // como si implementara una pequeña interfaz de compilación.
    const Mapping = @TypeOf(mapping);
    const info = @typeInfo(Mapping);
    // Las tuplas también tienen información de tipo struct en Zig: se excluyen explícitamente.
    if (info != .@"struct" or info.@"struct".is_tuple)
        @compileError("PostgreSQL type mapping '" ++ name ++ "': must be a struct like .{ .sql_type = \"TEXT\" }");
    // Un mapping tiene una sola responsabilidad. Rechazar campos adicionales
    // permite detectar errores de escritura en lugar de ignorarlos en silencio.
    if (info.@"struct".field_names.len != 1 or !@hasField(Mapping, "sql_type"))
        @compileError("PostgreSQL type mapping '" ++ name ++ "': must contain only 'sql_type'");
    // Valida tanto el tipo estático como el requisito de que el valor no esté vacío.
    if (!isStringType(@TypeOf(mapping.sql_type)))
        @compileError("PostgreSQL type mapping '" ++ name ++ "': 'sql_type' must be a non-empty string");
    if (mapping.sql_type.len == 0)
        @compileError("PostgreSQL type mapping '" ++ name ++ "': 'sql_type' must be a non-empty string");
}

fn checkTypeMappings(comptime mappings: anytype) void {
    // La colección es un struct anónimo cuyas claves son los nombres de tipos de dominio.
    const info = @typeInfo(@TypeOf(mappings));
    if (info != .@"struct" or info.@"struct".is_tuple)
        @compileError("PostgreSQL type mappings must be a struct of TypeMapping values");
    // `inline for` despliega una validación por mapping y produce un error que
    // identifica el tipo de dominio exacto que lo causó.
    inline for (info.@"struct".field_names) |name| {
        checkTypeMapping(@field(mappings, name), name);
    }
}

/// Valida los mappings PostgreSQL de tipos de dominio en su declaración y
/// los devuelve sin cambios, conservando el tipo exacto del struct anónimo.
pub fn defineTypeMappings(comptime mappings: anytype) @TypeOf(mappings) {
    // Este es el patrón `satisfies` de Zigma: valida sin convertir a un contenedor
    // común de runtime y así conserva los nombres de campos para la reflexión.
    comptime checkTypeMappings(mappings);
    return mappings;
}

fn validateIdentifier(comptime identifier: []const u8) void {
    // Un nombre vacío produciría comillas válidas (`""`), pero no es una parte
    // útil ni soportada del contrato PostgreSQL de este framework.
    if (identifier.len == 0)
        @compileError("PostgreSQL identifiers must not be empty");
    if (identifier.len > max_identifier_bytes)
        @compileError("PostgreSQL identifier '" ++ identifier ++ "' exceeds 63 bytes");
}

fn QuotedIdentifier(comptime identifier: []const u8) type {
    // Un tipo contenedor generado da almacenamiento estático al array de bytes.
    // La primera pasada calcula el tamaño exacto: las comillas delimitadoras más
    // un byte adicional por cada comilla interna que PostgreSQL exige duplicar.
    const quoted_len = blk: {
        var len: usize = 2;
        for (identifier) |char| len += if (char == '\"') 2 else 1;
        break :blk len;
    };
    return struct {
        // La segunda pasada llena un array de tamaño fijo. Como se conocen el tamaño
        // y la entrada, no se necesita allocator ni hay costo de formato en runtime.
        const value: [quoted_len]u8 = blk: {
            var result: [quoted_len]u8 = undefined;
            var index: usize = 0;
            // Los identificadores delimitados de PostgreSQL empiezan con comillas dobles.
            result[index] = '\"';
            index += 1;
            for (identifier) |char| {
                // Primero copia el byte original...
                result[index] = char;
                index += 1;
                if (char == '\"') {
                    // ...y duplica las comillas para escaparlas (`a"b` se convierte
                    // en `"a""b"` en SQL).
                    result[index] = '\"';
                    index += 1;
                }
            }
            // Cierra el identificador delimitado y publica el array completo.
            result[index] = '\"';
            break :blk result;
        };
    };
}

fn quoteIdentifier(comptime identifier: []const u8) []const u8 {
    // La validación y la generación se mantienen juntas para impedir que
    // se emita por accidente un identificador generado sin comprobar.
    validateIdentifier(identifier);
    // Tomar la dirección del almacenamiento del contenedor devuelve un slice con
    // vida estática del programa, válido dentro del string SQL generado en comptime.
    return &QuotedIdentifier(identifier).value;
}

fn quoteNameList(comptime names: anytype) []const u8 {
    // La repetición de `++` es aceptable acá porque la función se evalúa en
    // compilación y construye un único resultado inmutable en el binario.
    comptime var result: []const u8 = "";
    comptime var index: usize = 0;
    inline while (index < names.len) : (index += 1) {
        // Se inserta una coma antes de cada elemento salvo el primero, evitando
        // un caso especial para la coma final en la sintaxis de restricciones generada.
        if (index != 0) result = result ++ ", ";
        result = result ++ quoteIdentifier(names[index]);
    }
    return result;
}

fn quoteStructFieldNames(comptime StructType: type) []const u8 {
    // Los mappings de FK son structs cuyos *nombres de campos* son columnas de origen.
    comptime var result: []const u8 = "";
    inline for (@typeInfo(StructType).@"struct".field_names, 0..) |name, index| {
        if (index != 0) result = result ++ ", ";
        result = result ++ quoteIdentifier(name);
    }
    return result;
}

fn quoteStructFieldValues(comptime values: anytype) []const u8 {
    // Los *valores* del struct son nombres de columnas de destino. Generar nombres
    // y valores por separado admite FKs con campos renombrados, como jefe→docente.
    comptime var result: []const u8 = "";
    inline for (@typeInfo(@TypeOf(values)).@"struct".field_names, 0..) |name, index| {
        if (index != 0) result = result ++ ", ";
        result = result ++ quoteIdentifier(@field(values, name));
    }
    return result;
}

fn sqlTypeFor(
    comptime table_name: []const u8,
    comptime field_name: []const u8,
    comptime domain_type: []const u8,
    comptime type_mappings: anytype,
) []const u8 {
    // Los tipos de dominio son independientes de la base de datos. El backend
    // PostgreSQL los resuelve acá y emite un error de compilación específico
    // cuando falta un mapping de destino.
    if (!@hasField(@TypeOf(type_mappings), domain_type))
        @compileError("entity '" ++ table_name ++ "', field '" ++ field_name ++ "': missing PostgreSQL type mapping for domain type '" ++ domain_type ++ "'");
    return @field(type_mappings, domain_type).sql_type;
}

fn primaryConstraintName(comptime table_name: []const u8) []const u8 {
    // Los nombres deterministas hacen que snapshots, migraciones y comparaciones
    // de catálogo sean estables entre máquinas y compilaciones.
    return "pk_" ++ table_name;
}

fn uniqueConstraintName(comptime table_name: []const u8, comptime uk_name: []const u8) []const u8 {
    return "uk_" ++ table_name ++ "_" ++ uk_name;
}

fn foreignConstraintName(comptime table_name: []const u8, comptime fk_name: []const u8) []const u8 {
    return "fk_" ++ table_name ++ "_" ++ fk_name;
}

fn renderTable(
    comptime table_name: []const u8,
    comptime entity: anytype,
    comptime type_mappings: anytype,
    comptime if_not_exists: bool,
) []const u8 {
    // Toda la generación ocurre en comptime; el slice devuelto es una
    // constante inmutable incorporada al programa final.
    validateIdentifier(table_name);
    // La entidad proviene de Model.info, con defaults y nulabilidad efectivos.
    const info = entity;
    // El diseño de CRUD y migraciones supone que cada tabla gestionada tiene identidad.
    if (info.pk.len == 0)
        @compileError("entity '" ++ table_name ++ "': PostgreSQL DDL requires a non-empty pk");

    // Inicia la sentencia y elige entre inicialización (`IF NOT EXISTS`) o baseline
    // estricto. El salto de línea inicia un formato legible para personas.
    comptime var ddl: []const u8 = "CREATE TABLE " ++
        (if (if_not_exists) "IF NOT EXISTS " else "") ++
        quoteIdentifier(table_name) ++ " (\n";

    // La reflexión del struct conserva el orden de declaración de las columnas.
    inline for (@typeInfo(@TypeOf(info.fields)).@"struct".field_names) |field_name| {
        validateIdentifier(field_name);
        const field = @field(info.fields, field_name);
        const sql_type = sqlTypeFor(table_name, field_name, field.type, type_mappings);
        // Model.info ya incorpora las restricciones de la PK en la nulabilidad.
        const not_null = !field.nullable;
        ddl = ddl ++ "    " ++ quoteIdentifier(field_name) ++ " " ++ sql_type ++ (if (not_null) " NOT NULL" else "") ++ ",\n";
    }

    // Las restricciones son de tabla y tienen un orden estable por categoría: primero la PK...
    ddl = ddl ++ "    CONSTRAINT " ++ quoteIdentifier(primaryConstraintName(table_name)) ++
        " PRIMARY KEY (" ++ quoteNameList(info.pk) ++ ")";

    // ...después cada clave única, en orden de declaración...
    inline for (@typeInfo(@TypeOf(info.uks)).@"struct".field_names) |uk_name| {
        const constraint_name = uniqueConstraintName(table_name, uk_name);
        ddl = ddl ++ ",\n    CONSTRAINT " ++ quoteIdentifier(constraint_name) ++
            " UNIQUE (" ++ quoteNameList(@field(info.uks, uk_name)) ++ ")";
    }

    // ...y luego cada clave foránea. `fk.fields` es el mapa normalizado
    // origen→destino que produce `completeEntity`.
    inline for (@typeInfo(@TypeOf(info.fks)).@"struct".field_names) |fk_name| {
        const fk = @field(info.fks, fk_name);
        const constraint_name = foreignConstraintName(table_name, fk_name);
        ddl = ddl ++ ",\n    CONSTRAINT " ++ quoteIdentifier(constraint_name) ++
            " FOREIGN KEY (" ++ quoteStructFieldNames(@TypeOf(fk.fields)) ++ ")" ++
            " REFERENCES " ++ quoteIdentifier(fk.entity) ++
            " (" ++ quoteStructFieldValues(fk.fields) ++ ")";
    }

    // Cada sentencia termina en `;\n`; la generación del schema agrega
    // una línea en blanco entre sentencias sucesivas.
    return ddl ++ "\n);\n";
}

fn RenderedTable(
    comptime table_name: []const u8,
    comptime entity: anytype,
    comptime type_mappings: anytype,
    comptime if_not_exists: bool,
) type {
    // Como con los identificadores entrecomillados, una declaración contenedora da
    // almacenamiento comptime estable al string y evita reevaluarlo en cada acceso.
    return struct {
        const value: []const u8 = renderTable(table_name, entity, type_mappings, if_not_exists);
    };
}

fn indexOfName(comptime names: anytype, comptime wanted: []const u8) usize {
    // La validación global ya comprobó que existen todos los destinos de FK.
    // Un fallo acá sería un estado interno imposible, no un error del usuario.
    for (names, 0..) |name, index| {
        if (eql(name, wanted)) return index;
    }
    unreachable;
}

fn SchemaOrder(comptime entity_defs: anytype) type {
    // Este ordenamiento topológico estable se evalúa íntegramente en el compilador.
    const entity_names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;
    return struct {
        const names: [entity_names.len][:0]const u8 = blk: {
            // `result` guarda el orden final; `emitted` marca los nodos ya ubicados.
            // Se pueden usar arrays fijos porque se conoce la cantidad de entidades.
            var result: [entity_names.len][:0]const u8 = undefined;
            var emitted: [entity_names.len]bool = @splat(false);
            var result_len: usize = 0;

            // Cada pasada emite las tablas cuyas dependencias externas
            // ya se emitieron.
            while (result_len < entity_names.len) {
                var made_progress = false;
                for (entity_names, 0..) |entity_name, entity_index| {
                    // Recorrer en orden de declaración hace que las tablas
                    // independientes conserven su orden original estable.
                    if (emitted[entity_index]) continue;
                    const entity = @field(entity_defs, entity_name);
                    var dependencies_ready = true;
                    for (@typeInfo(@TypeOf(entity.fks)).@"struct".field_names) |fk_name| {
                        const target = @field(entity.fks, fk_name).entity;
                        // Una FK reflexiva pertenece al CREATE TABLE de su propia tabla
                        // y no requiere que se haya emitido otra tabla antes.
                        if (eql(target, entity_name)) continue;
                        if (!emitted[indexOfName(entity_names, target)]) {
                            dependencies_ready = false;
                            break;
                        }
                    }
                    // Cuando todos los destinos están listos, esta tabla puede
                    // generar sus restricciones FK dentro del CREATE TABLE.
                    if (dependencies_ready) {
                        result[result_len] = entity_name;
                        result_len += 1;
                        emitted[entity_index] = true;
                        made_progress = true;
                    }
                }
                // Si quedan nodos y no se avanza, hay un ciclo entre tablas distintas.
                // Las restricciones dentro de CREATE TABLE no pueden representarlo
                // sin una fase posterior de ALTER TABLE.
                if (!made_progress) {
                    for (entity_names, 0..) |entity_name, entity_index| {
                        if (!emitted[entity_index])
                            @compileError("PostgreSQL DDL: foreign key cycle involving entity '" ++ entity_name ++ "' cannot be generated with inline constraints");
                    }
                    unreachable;
                }
            }
            break :blk result;
        };
    };
}

/// Genera una sentencia `CREATE TABLE IF NOT EXISTS` completa. Recibe toda la
/// información normalizada de Model para seleccionar la tabla solicitada.
pub fn createTableDdl(
    comptime Model: type,
    comptime table_name: []const u8,
    comptime type_mappings: anytype,
) []const u8 {
    // Valida los mappings específicos del destino antes de seleccionar una entidad.
    comptime checkTypeMappings(type_mappings);
    // System ya comprobó que cada FK apunte a una PK o UK real del sistema.
    const model_info = Model.info;
    if (!@hasField(@TypeOf(model_info), table_name))
        @compileError("PostgreSQL DDL: unknown entity '" ++ table_name ++ "'");
    // El nombre de tabla es una entrada comptime: la selección produce un string
    // inmutable especializado, sin búsquedas ni reservas de memoria en runtime.
    return RenderedTable(table_name, @field(model_info, table_name), type_mappings, true).value;
}

/// Genera el schema PostgreSQL completo. Las tablas referenciadas preceden a
/// sus dependientes; las entidades independientes conservan el orden de declaración;
/// las claves foráneas reflexivas permanecen dentro del CREATE TABLE.
pub fn createSchemaDdl(comptime Model: type, comptime type_mappings: anytype) []const u8 {
    comptime checkTypeMappings(type_mappings);
    const model_info = Model.info;
    // Concatena las sentencias ya generadas en orden de dependencias. Esto ocurre
    // solo durante la compilación; runtime recibe el slice terminado.
    comptime var ddl: []const u8 = "";
    inline for (SchemaOrder(model_info).names, 0..) |table_name, index| {
        // Una línea en blanco separa las sentencias; cada generador de tabla
        // aporta su propio salto de línea final.
        if (index != 0) ddl = ddl ++ "\n";
        ddl = ddl ++ RenderedTable(table_name, @field(model_info, table_name), type_mappings, true).value;
    }
    return ddl;
}

/// Genera la migración inicial para una base de datos vacía. A diferencia de
/// `createSchemaDdl`, omite `IF NOT EXISTS`: el historial de migraciones debe
/// detectar divergencias en lugar de aceptar objetos preexistentes en silencio.
pub fn createBaselineDdl(comptime Model: type, comptime type_mappings: anytype) []const u8 {
    comptime checkTypeMappings(type_mappings);
    const model_info = Model.info;
    // La generación del baseline comparte validación y orden con el DDL normal;
    // solo `if_not_exists = false` cambia el nivel de exigencia.
    comptime var ddl: []const u8 = "";
    inline for (SchemaOrder(model_info).names, 0..) |table_name, index| {
        if (index != 0) ddl = ddl ++ "\n";
        ddl = ddl ++ RenderedTable(table_name, @field(model_info, table_name), type_mappings, false).value;
    }
    return ddl;
}
