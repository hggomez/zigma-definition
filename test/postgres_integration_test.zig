const std = @import("std");
const zigma = @import("zigma");
const aida = @import("aida");
const postgres_ddl = @import("zigma_postgres_ddl");
const postgres_executor = @import("zigma_postgres_executor");
const postgres_libpq = @import("zigma_postgres_libpq");

const type_mappings = postgres_ddl.defineTypeMappings(zigma.merge(.{
    postgres_ddl.common_type_mappings,
    .{
        .fecha = postgres_ddl.TypeMapping{ .sql_type = "DATE" },
        .email = postgres_ddl.TypeMapping{ .sql_type = "TEXT" },
    },
}));

const schema_ddl = postgres_ddl.createSchemaDdl(aida.entity_defs, type_mappings);

fn environmentValue(comptime name: [:0]const u8) ![]const u8 {
    const value = std.c.getenv(name) orelse return error.MissingIntegrationEnvironment;
    return std.mem.span(value);
}

fn validateSchemaName(name: []const u8) !void {
    if (name.len == 0) return error.InvalidIntegrationSchema;
    for (name) |char| {
        if (!std.ascii.isAlphanumeric(char) and char != '_')
            return error.InvalidIntegrationSchema;
    }
}

fn expectPostgresError(connection: *const postgres_libpq.Connection, result: anyerror!void) !void {
    try std.testing.expectError(error.PostgresError, result);
    const message = connection.lastError() orelse return error.MissingPostgresErrorMessage;
    try std.testing.expect(message.len != 0);
}

test "executes and verifies the complete AIDA schema in PostgreSQL" {
    const allocator = std.testing.allocator;
    const database_url = try environmentValue("ZIGMA_POSTGRES_URL");
    const schema_name = try environmentValue("ZIGMA_POSTGRES_SCHEMA");
    try validateSchemaName(schema_name);

    var connection = postgres_libpq.Connection.init(allocator);
    defer connection.deinit();
    try connection.connect(database_url);

    const setup_sql = try std.fmt.allocPrint(
        allocator,
        "CREATE SCHEMA \"{s}\"; SET search_path TO \"{s}\"",
        .{ schema_name, schema_name },
    );
    defer allocator.free(setup_sql);
    try connection.exec(setup_sql);

    const cleanup_sql = try std.fmt.allocPrint(
        allocator,
        "DROP SCHEMA IF EXISTS \"{s}\" CASCADE",
        .{schema_name},
    );
    defer allocator.free(cleanup_sql);
    defer connection.exec(cleanup_sql) catch {};

    try postgres_executor.executeSchema(&connection, schema_ddl);

    const catalog_assertions =
        \\DO $$
        \\DECLARE
        \\    actual_tables text[];
        \\BEGIN
        \\    SELECT array_agg(table_name ORDER BY table_name)
        \\      INTO actual_tables
        \\      FROM information_schema.tables
        \\     WHERE table_schema = current_schema()
        \\       AND table_type = 'BASE TABLE';
        \\    IF actual_tables IS DISTINCT FROM ARRAY[
        \\        'alumnos', 'clases', 'cursos', 'docentes', 'inscripciones',
        \\        'materias', 'mesas', 'opciones', 'periodos', 'preguntas', 'presencias'
        \\    ]::text[] THEN
        \\        RAISE EXCEPTION 'unexpected tables: %', actual_tables;
        \\    END IF;
        \\    IF (SELECT count(*) FROM information_schema.columns
        \\         WHERE table_schema = current_schema()) <> 47 THEN
        \\        RAISE EXCEPTION 'unexpected column count';
        \\    END IF;
        \\    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
        \\        WHERE table_schema = current_schema() AND table_name = 'materias'
        \\          AND column_name = 'materia' AND data_type = 'text' AND is_nullable = 'NO') THEN
        \\        RAISE EXCEPTION 'materias.materia metadata mismatch';
        \\    END IF;
        \\    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
        \\        WHERE table_schema = current_schema() AND table_name = 'docentes'
        \\          AND column_name = 'email' AND data_type = 'text' AND is_nullable = 'YES') THEN
        \\        RAISE EXCEPTION 'docentes.email metadata mismatch';
        \\    END IF;
        \\    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
        \\        WHERE table_schema = current_schema() AND table_name = 'clases'
        \\          AND column_name = 'orden' AND data_type = 'bigint' AND is_nullable = 'NO') THEN
        \\        RAISE EXCEPTION 'clases.orden metadata mismatch';
        \\    END IF;
        \\    IF NOT EXISTS (SELECT 1 FROM information_schema.columns
        \\        WHERE table_schema = current_schema() AND table_name = 'clases'
        \\          AND column_name = 'fecha' AND data_type = 'date' AND is_nullable = 'YES') THEN
        \\        RAISE EXCEPTION 'clases.fecha metadata mismatch';
        \\    END IF;
        \\    IF NOT EXISTS (SELECT 1 FROM pg_constraint
        \\        WHERE conname = 'pk_cursos'
        \\          AND pg_get_constraintdef(oid) = 'PRIMARY KEY (periodo, materia)') THEN
        \\        RAISE EXCEPTION 'composite pk mismatch';
        \\    END IF;
        \\    IF NOT EXISTS (SELECT 1 FROM pg_constraint
        \\        WHERE conname = 'uk_materias_denominacion'
        \\          AND pg_get_constraintdef(oid) = 'UNIQUE (denominacion)') THEN
        \\        RAISE EXCEPTION 'unique constraint mismatch';
        \\    END IF;
        \\    IF NOT EXISTS (SELECT 1 FROM pg_constraint
        \\        WHERE conname = 'fk_cursos_periodos'
        \\          AND pg_get_constraintdef(oid) = 'FOREIGN KEY (periodo) REFERENCES periodos(periodo)') THEN
        \\        RAISE EXCEPTION 'simple fk mismatch';
        \\    END IF;
        \\    IF NOT EXISTS (SELECT 1 FROM pg_constraint
        \\        WHERE conname = 'fk_presencias_clases'
        \\          AND pg_get_constraintdef(oid) = 'FOREIGN KEY (periodo, materia, orden) REFERENCES clases(periodo, materia, orden)') THEN
        \\        RAISE EXCEPTION 'composite fk mismatch';
        \\    END IF;
        \\    IF NOT EXISTS (SELECT 1 FROM pg_constraint
        \\        WHERE conname = 'fk_docentes_jefe'
        \\          AND pg_get_constraintdef(oid) = 'FOREIGN KEY (jefe) REFERENCES docentes(docente)') THEN
        \\        RAISE EXCEPTION 'reflexive fk mismatch';
        \\    END IF;
        \\    IF NOT EXISTS (SELECT 1 FROM pg_constraint
        \\        WHERE conname = 'fk_mesas_presidente'
        \\          AND pg_get_constraintdef(oid) = 'FOREIGN KEY (presidente) REFERENCES docentes(docente)')
        \\       OR NOT EXISTS (SELECT 1 FROM pg_constraint
        \\        WHERE conname = 'fk_mesas_vocal'
        \\          AND pg_get_constraintdef(oid) = 'FOREIGN KEY (vocal) REFERENCES docentes(docente)') THEN
        \\        RAISE EXCEPTION 'renamed fks mismatch';
        \\    END IF;
        \\END
        \\$$;
    ;

    try connection.exec(catalog_assertions);

    // CREATE TABLE IF NOT EXISTS makes the initial schema bootstrap idempotent.
    try postgres_executor.executeSchema(&connection, schema_ddl);
    try connection.exec(catalog_assertions);

    const invalid_ddl =
        \\CREATE TABLE rollback_probe (id BIGINT PRIMARY KEY);
        \\THIS IS NOT VALID SQL;
    ;
    try expectPostgresError(
        &connection,
        postgres_executor.executeSchema(&connection, invalid_ddl),
    );

    try connection.exec(
        \\DO $$
        \\BEGIN
        \\    IF to_regclass('rollback_probe') IS NOT NULL THEN
        \\        RAISE EXCEPTION 'rollback_probe survived rollback';
        \\    END IF;
        \\END
        \\$$;
    );
}
