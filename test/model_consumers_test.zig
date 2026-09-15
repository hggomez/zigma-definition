//! Comprueba la misma interpretación del contrato en los tipos, REST, DDL y CRUD.
//! La conexión falsa verifica SQL y parámetros durante la llamada; no retiene
//! referencias a memoria de la solicitud después de que termina Api.handle.
const std = @import("std");
const zigma = @import("zigma");
const rest = @import("zigma_rest");
const ddl = @import("zigma_postgres_ddl");
const migrations = @import("zigma_postgres_migrations");
const crud = @import("zigma_postgres_crud");
const aida = @import("aida");
const aida_postgres = @import("aida_postgres");

fn modelFor(comptime nullable: bool, comptime rules: anytype) type {
    return zigma.System(zigma.common_type_defs, .{
        .things = zigma.defineEntity(.{
            .pk = .{"id"},
            .fields = zigma.record(zigma.common_type_defs, .{
                .id = .{ .type = "integer", .nullable = true },
                .note = .{ .type = "text", .nullable = nullable },
            }),
            .rules = rules,
        }),
    });
}

const FakeConnection = struct {
    expected_sql: []const u8,
    expected_parameters: []const ?[]const u8,
    calls: usize = 0,
    row: [2]?[]const u8 = .{ "7", null },

    const Error = error{ UnexpectedSql, UnexpectedParameter };

    // Las columnas son estáticas y la fila pertenece a FakeConnection, que
    // sobrevive a la llamada síncrona. Este resultado no reserva memoria.
    const Result = struct {
        columns: []const []const u8 = &.{ "id", "note" },
        rows: [1][]const ?[]const u8,

        pub fn deinit(_: *@This()) void {}
    };

    pub fn queryParams(
        self: *@This(),
        _: std.mem.Allocator,
        sql: []const u8,
        parameters: []const ?[]const u8,
    ) Error!Result {
        self.calls += 1;
        if (!std.mem.eql(u8, self.expected_sql, sql)) return error.UnexpectedSql;
        if (self.expected_parameters.len != parameters.len) return error.UnexpectedParameter;
        for (self.expected_parameters, parameters) |expected, actual| {
            if (expected) |value| {
                if (actual == null or !std.mem.eql(u8, value, actual.?)) return error.UnexpectedParameter;
            } else if (actual != null) return error.UnexpectedParameter;
        }
        return .{ .rows = .{&self.row} };
    }

    pub fn lastSqlState(_: *const @This()) ?[]const u8 {
        return null;
    }
};

test "row types, DDL and snapshots agree on effective PK and field nullability" {
    inline for (.{ true, false }) |nullable| {
        const Model = modelFor(nullable, .{});
        try std.testing.expect(!Model.info.things.fields.id.nullable);
        try std.testing.expect(Model.info.things.fields.note.nullable == nullable);
        try std.testing.expect(@FieldType(Model.Row("things"), "id") == i64);
        try std.testing.expect(@FieldType(Model.Row("things"), "note") == if (nullable) ?[]const u8 else []const u8);

        const expected_ddl = "CREATE TABLE IF NOT EXISTS \"things\" (\n" ++
            "    \"id\" BIGINT NOT NULL,\n" ++
            "    \"note\" TEXT" ++ (if (nullable) "" else " NOT NULL") ++ ",\n" ++
            "    CONSTRAINT \"pk_things\" PRIMARY KEY (\"id\")\n);\n";
        try std.testing.expectEqualStrings(expected_ddl, ddl.createTableDdl(Model, "things", ddl.common_type_mappings));

        const snapshot = migrations.createSchemaSnapshot(Model, ddl.common_type_mappings);
        var parsed = try migrations.parseSnapshot(std.testing.allocator, snapshot);
        defer parsed.deinit();
        try std.testing.expect(!parsed.value.tables[0].columns[0].nullable);
        try std.testing.expect(parsed.value.tables[0].columns[1].nullable == nullable);
    }
}

test "REST POST uses Model nullability before any SQL mutation" {
    inline for (.{ true, false }) |nullable| {
        const Model = modelFor(nullable, .{});
        const Api = rest.Api(Model, rest.common_codecs);
        var api = Api.init(.{});
        const cases = .{
            .{ .body = "{\"id\":7}", .valid = nullable },
            .{ .body = "{\"id\":7,\"note\":null}", .valid = nullable },
            .{ .body = "{\"id\":null,\"note\":\"memo\"}", .valid = false },
            .{ .body = "{\"note\":\"memo\"}", .valid = false },
        };
        inline for (cases) |case| {
            var connection = FakeConnection{
                .expected_sql = "INSERT INTO \"things\" (\"id\", \"note\") VALUES ($1, $2) RETURNING *",
                .expected_parameters = &.{ "7", null },
            };
            var repository = crud.Repository(Model).init(&connection);
            const response = try api.handle(std.testing.allocator, &repository, .{
                .method = .POST,
                .target = "/api/things",
                .content_type = "application/json",
                .body = case.body,
            });
            defer std.testing.allocator.free(response.body);
            try std.testing.expect(response.status == if (case.valid) @as(u16, 201) else @as(u16, 400));
            try std.testing.expect(connection.calls == if (case.valid) @as(usize, 1) else @as(usize, 0));
            if (case.valid) try std.testing.expectEqualStrings("{\"id\":7,\"note\":null}", response.body);
        }
    }
}

test "REST PUT uses Model nullability while preserving parameter order" {
    inline for (.{ true, false }) |nullable| {
        const Model = modelFor(nullable, .{});
        const Api = rest.Api(Model, rest.common_codecs);
        var api = Api.init(.{});
        var connection = FakeConnection{
            .expected_sql = "UPDATE \"things\" SET \"note\" = $1 WHERE \"id\" = $2 RETURNING *",
            .expected_parameters = &.{ null, "7" },
        };
        var repository = crud.Repository(Model).init(&connection);
        const response = try api.handle(std.testing.allocator, &repository, .{
            .method = .PUT,
            .target = "/api/things?id=7",
            .content_type = "application/json",
            .body = "{\"note\":null}",
        });
        defer std.testing.allocator.free(response.body);
        try std.testing.expect(response.status == if (nullable) @as(u16, 200) else @as(u16, 400));
        try std.testing.expect(connection.calls == if (nullable) @as(usize, 1) else @as(usize, 0));
        if (nullable) try std.testing.expectEqualStrings("[{\"id\":7,\"note\":null}]", response.body);
    }
}

test "REST and CRUD keep text null distinct from SQL NULL filters" {
    const Model = modelFor(true, .{});
    const Api = rest.Api(Model, rest.common_codecs);
    var api = Api.init(.{});
    var connection = FakeConnection{
        .expected_sql = "SELECT * FROM \"things\" WHERE \"id\" = $1 AND \"note\" = $2",
        .expected_parameters = &.{ "7", "null" },
        .row = .{ "7", "null" },
    };
    var repository = crud.Repository(Model).init(&connection);
    const response = try api.handle(std.testing.allocator, &repository, .{
        .method = .GET,
        .target = "/api/things?note=null&id=7",
    });
    defer std.testing.allocator.free(response.body);
    try std.testing.expect(response.status == 200);
    try std.testing.expect(connection.calls == 1);
    try std.testing.expectEqualStrings("[{\"id\":7,\"note\":\"null\"}]", response.body);
}

test "adding or changing rule metadata leaves every PostgreSQL artifact unchanged" {
    const Plain = modelFor(true, .{});
    const WithRule = modelFor(true, .{ .display = .{ .fields = .{"note"} } });
    const ChangedRule = modelFor(true, .{ .display = .{ .fields = .{ "id", "note" } } });
    inline for (.{ WithRule, ChangedRule }) |Model| {
        try std.testing.expectEqualStrings(
            ddl.createTableDdl(Plain, "things", ddl.common_type_mappings),
            ddl.createTableDdl(Model, "things", ddl.common_type_mappings),
        );
        try std.testing.expectEqualStrings(
            ddl.createSchemaDdl(Plain, ddl.common_type_mappings),
            ddl.createSchemaDdl(Model, ddl.common_type_mappings),
        );
        try std.testing.expectEqualStrings(
            ddl.createBaselineDdl(Plain, ddl.common_type_mappings),
            ddl.createBaselineDdl(Model, ddl.common_type_mappings),
        );
        const plain_snapshot = comptime migrations.createSchemaSnapshot(Plain, ddl.common_type_mappings);
        const snapshot = migrations.createSchemaSnapshot(Model, ddl.common_type_mappings);
        try std.testing.expectEqualStrings(plain_snapshot, snapshot);
        migrations.assertAcceptedSnapshot(Model, ddl.common_type_mappings, plain_snapshot);
        var diff = try migrations.diffSnapshots(std.testing.allocator, plain_snapshot, snapshot);
        defer diff.deinit();
        try std.testing.expect(diff.changes.len == 0);
    }
}

fn rejectBlockedNote(values: []const rest.FieldValue) rest.BusinessValidationError!?rest.BusinessRuleViolation {
    for (values) |value| {
        if (std.mem.eql(u8, value.name, "note")) {
            if (value.value) |note| {
                if (std.mem.eql(u8, note, "blocked")) return .{ .code = "blocked_note", .message = "Blocked note" };
            }
            return null;
        }
    }
    return error.InvalidState;
}

test "existing business validator composition accepts Model and still rejects before INSERT" {
    const Model = modelFor(true, .{});
    const validators = rest.defineBusinessValidators(Model, .{
        .things = rest.BusinessValidator{ .validate = rejectBlockedNote },
    });
    const Api = rest.ApiWithBusinessValidators(Model, rest.common_codecs, validators);
    var api = Api.init(.{});
    var connection = FakeConnection{ .expected_sql = "", .expected_parameters = &.{} };
    var repository = crud.Repository(Model).init(&connection);
    const response = try api.handle(std.testing.allocator, &repository, .{
        .method = .POST,
        .target = "/api/things",
        .content_type = "application/json",
        .body = "{\"id\":7,\"note\":\"blocked\"}",
    });
    defer std.testing.allocator.free(response.body);
    try std.testing.expect(response.status == 422);
    try std.testing.expect(connection.calls == 0);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "blocked_note") != null);
}

test "AIDA publishes Model without changing generated bootstrap SQL" {
    try std.testing.expectEqualStrings(
        @embedFile("fixtures/aida-bootstrap-before-model.sql"),
        ddl.createSchemaDdl(aida.Model, aida_postgres.type_mappings),
    );
}
