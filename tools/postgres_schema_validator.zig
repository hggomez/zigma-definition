//! Database-backed proof that a migrated schema equals the current AIDA SSOT.
//!
//! It creates a temporary expected schema from the compile-time baseline DDL,
//! compares PostgreSQL catalog structures, and always attempts to remove the
//! temporary schema. It never changes objects in the actual schema.

const std = @import("std");
const postgres = @import("aida_postgres");
const libpq = @import("zigma_postgres_libpq");

const expected_schema = "_zigma_expected_validation";

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const baseline_adoption = if (args.next()) |arg| blk: {
        if (!std.mem.eql(u8, arg, "--baseline-adoption")) return error.InvalidArgument;
        break :blk true;
    } else false;
    if (args.next() != null) return error.InvalidArgument;

    const database_url = init.environ_map.get("DATABASE_URL") orelse {
        std.debug.print("DATABASE_URL is required by postgres-schema-validator\n", .{});
        return error.MissingDatabaseUrl;
    };
    const actual_schema = init.environ_map.get("ZIGMA_ACTUAL_SCHEMA") orelse "public";
    if (!validIdentifier(actual_schema) or std.mem.eql(u8, actual_schema, expected_schema))
        return error.InvalidSchemaName;

    var connection = libpq.Connection.init(init.gpa);
    defer connection.deinit();
    connection.connect(database_url) catch |err| {
        printDatabaseError(&connection, err);
        return err;
    };

    const setup_sql = try std.fmt.allocPrint(
        init.gpa,
        "CREATE SCHEMA \"{s}\"; SET search_path TO \"{s}\", pg_catalog;\n{s}",
        .{ expected_schema, expected_schema, postgres.baseline_ddl },
    );
    defer init.gpa.free(setup_sql);
    connection.exec(setup_sql) catch |err| {
        printDatabaseError(&connection, err);
        return err;
    };
    defer connection.exec("DROP SCHEMA \"_zigma_expected_validation\" CASCADE") catch {};

    const comparison_sql = try catalogComparisonSql(init.gpa, actual_schema);
    defer init.gpa.free(comparison_sql);
    connection.exec(comparison_sql) catch |err| {
        printDatabaseError(&connection, err);
        return err;
    };
    if (baseline_adoption) {
        const history_sql = try baselineHistorySql(init.gpa, actual_schema);
        defer init.gpa.free(history_sql);
        connection.exec(history_sql) catch |err| {
            printDatabaseError(&connection, err);
            return err;
        };
    }
    std.debug.print("PostgreSQL schema '{s}' matches the compiled Zigma model\n", .{actual_schema});
}

fn validIdentifier(value: []const u8) bool {
    if (value.len == 0 or value.len > 63) return false;
    for (value) |byte| if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
    return true;
}

fn catalogComparisonSql(allocator: std.mem.Allocator, actual: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\DO $$
        \\BEGIN
        \\  IF EXISTS (
        \\    WITH actual AS (
        \\      SELECT c.relname
        \\      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        \\      WHERE n.nspname = '{s}' AND c.relkind IN ('r','p')
        \\        AND lower(c.relname) NOT IN ('databasechangelog','databasechangeloglock')
        \\    ), expected AS (
        \\      SELECT c.relname
        \\      FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
        \\      WHERE n.nspname = '{s}' AND c.relkind IN ('r','p')
        \\    )
        \\    (SELECT * FROM actual EXCEPT SELECT * FROM expected)
        \\    UNION ALL
        \\    (SELECT * FROM expected EXCEPT SELECT * FROM actual)
        \\  ) THEN RAISE EXCEPTION 'Zigma schema validation: table set differs'; END IF;
        \\
        \\  IF EXISTS (
        \\    WITH actual AS (
        \\      SELECT c.relname AS table_name, a.attnum, a.attname, a.atttypid, a.atttypmod, a.attnotnull, a.attcollation
        \\      FROM pg_attribute a
        \\      JOIN pg_class c ON c.oid = a.attrelid
        \\      JOIN pg_namespace n ON n.oid = c.relnamespace
        \\      WHERE n.nspname = '{s}' AND c.relkind IN ('r','p') AND a.attnum > 0 AND NOT a.attisdropped
        \\        AND lower(c.relname) NOT IN ('databasechangelog','databasechangeloglock')
        \\    ), expected AS (
        \\      SELECT c.relname AS table_name, a.attnum, a.attname, a.atttypid, a.atttypmod, a.attnotnull, a.attcollation
        \\      FROM pg_attribute a
        \\      JOIN pg_class c ON c.oid = a.attrelid
        \\      JOIN pg_namespace n ON n.oid = c.relnamespace
        \\      WHERE n.nspname = '{s}' AND c.relkind IN ('r','p') AND a.attnum > 0 AND NOT a.attisdropped
        \\    )
        \\    (SELECT * FROM actual EXCEPT SELECT * FROM expected)
        \\    UNION ALL
        \\    (SELECT * FROM expected EXCEPT SELECT * FROM actual)
        \\  ) THEN RAISE EXCEPTION 'Zigma schema validation: columns, order, type, or nullability differ'; END IF;
        \\
        \\  IF EXISTS (
        \\    WITH actual AS (
        \\      SELECT src.relname AS table_name, con.conname, con.contype,
        \\        ARRAY(SELECT a.attname FROM unnest(con.conkey) WITH ORDINALITY k(attnum, ord)
        \\              JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum ORDER BY k.ord) AS columns,
        \\        COALESCE(dst_n.nspname = '{s}', false) AS target_is_managed_schema,
        \\        COALESCE(dst.relname, '') AS target_table,
        \\        ARRAY(SELECT a.attname FROM unnest(COALESCE(con.confkey, ARRAY[]::smallint[])) WITH ORDINALITY k(attnum, ord)
        \\              JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum ORDER BY k.ord) AS target_columns
        \\      FROM pg_constraint con
        \\      JOIN pg_class src ON src.oid = con.conrelid
        \\      JOIN pg_namespace n ON n.oid = src.relnamespace
        \\      LEFT JOIN pg_class dst ON dst.oid = con.confrelid
        \\      LEFT JOIN pg_namespace dst_n ON dst_n.oid = dst.relnamespace
        \\      WHERE n.nspname = '{s}' AND con.contype IN ('p','u','f')
        \\        AND lower(src.relname) NOT IN ('databasechangelog','databasechangeloglock')
        \\    ), expected AS (
        \\      SELECT src.relname AS table_name, con.conname, con.contype,
        \\        ARRAY(SELECT a.attname FROM unnest(con.conkey) WITH ORDINALITY k(attnum, ord)
        \\              JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum ORDER BY k.ord) AS columns,
        \\        COALESCE(dst_n.nspname = '{s}', false) AS target_is_managed_schema,
        \\        COALESCE(dst.relname, '') AS target_table,
        \\        ARRAY(SELECT a.attname FROM unnest(COALESCE(con.confkey, ARRAY[]::smallint[])) WITH ORDINALITY k(attnum, ord)
        \\              JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum ORDER BY k.ord) AS target_columns
        \\      FROM pg_constraint con
        \\      JOIN pg_class src ON src.oid = con.conrelid
        \\      JOIN pg_namespace n ON n.oid = src.relnamespace
        \\      LEFT JOIN pg_class dst ON dst.oid = con.confrelid
        \\      LEFT JOIN pg_namespace dst_n ON dst_n.oid = dst.relnamespace
        \\      WHERE n.nspname = '{s}' AND con.contype IN ('p','u','f')
        \\    )
        \\    (SELECT * FROM actual EXCEPT SELECT * FROM expected)
        \\    UNION ALL
        \\    (SELECT * FROM expected EXCEPT SELECT * FROM actual)
        \\  ) THEN RAISE EXCEPTION 'Zigma schema validation: PK, UK, or FK constraints differ'; END IF;
        \\END
        \\$$;
    , .{
        actual,          expected_schema,
        actual,          expected_schema,
        actual,          actual,
        expected_schema, expected_schema,
    });
}

fn baselineHistorySql(allocator: std.mem.Allocator, actual: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\DO $$
        \\DECLARE invalid_history boolean;
        \\BEGIN
        \\  IF to_regclass('"{s}"."databasechangelog"') IS NOT NULL THEN
        \\    EXECUTE format(
        \\      'SELECT count(*) > 1 OR count(*) FILTER (WHERE NOT (id = ''000001_baseline'' AND author = ''zigma'')) > 0 FROM %I.databasechangelog',
        \\      '{s}'
        \\    ) INTO invalid_history;
        \\    IF invalid_history THEN
        \\      RAISE EXCEPTION 'Zigma baseline adoption refused: database history is not empty or baseline-only';
        \\    END IF;
        \\  END IF;
        \\END
        \\$$;
    , .{ actual, actual });
}

fn printDatabaseError(connection: *const libpq.Connection, err: anyerror) void {
    if (connection.lastError()) |message|
        std.debug.print("PostgreSQL {t}: {s}\n", .{ err, message })
    else
        std.debug.print("PostgreSQL {t}\n", .{err});
}
