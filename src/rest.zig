//! Compile-time REST CRUD controllers derived from Zigma entities.
//!
//! This module owns routing, request validation, domain codecs and JSON. It
//! deliberately knows nothing about sockets or PostgreSQL; repositories are
//! matched structurally by `Api.handle`.

const std = @import("std");
const zigma = @import("zigma");

pub const CodecError = error{ InvalidValue, OutOfMemory };

pub const Codec = struct {
    queryToPostgres: *const fn (std.mem.Allocator, []const u8) CodecError![]const u8,
    jsonToPostgres: *const fn (std.mem.Allocator, std.json.Value) CodecError![]const u8,
    postgresToJson: *const fn (std.mem.Allocator, []const u8) CodecError!std.json.Value,
};

fn textFromQuery(allocator: std.mem.Allocator, value: []const u8) CodecError![]const u8 {
    return allocator.dupe(u8, value) catch error.OutOfMemory;
}

fn textFromJson(allocator: std.mem.Allocator, value: std.json.Value) CodecError![]const u8 {
    if (value != .string) return error.InvalidValue;
    return allocator.dupe(u8, value.string) catch error.OutOfMemory;
}

fn textToJson(_: std.mem.Allocator, value: []const u8) CodecError!std.json.Value {
    return .{ .string = value };
}

fn integerFromQuery(allocator: std.mem.Allocator, value: []const u8) CodecError![]const u8 {
    const parsed = std.fmt.parseInt(i64, value, 10) catch return error.InvalidValue;
    return std.fmt.allocPrint(allocator, "{d}", .{parsed}) catch error.OutOfMemory;
}

fn integerFromJson(allocator: std.mem.Allocator, value: std.json.Value) CodecError![]const u8 {
    if (value != .integer) return error.InvalidValue;
    return std.fmt.allocPrint(allocator, "{d}", .{value.integer}) catch error.OutOfMemory;
}

fn integerToJson(_: std.mem.Allocator, value: []const u8) CodecError!std.json.Value {
    return .{ .integer = std.fmt.parseInt(i64, value, 10) catch return error.InvalidValue };
}

fn booleanFromQuery(allocator: std.mem.Allocator, value: []const u8) CodecError![]const u8 {
    if (!std.mem.eql(u8, value, "true") and !std.mem.eql(u8, value, "false"))
        return error.InvalidValue;
    return allocator.dupe(u8, value) catch error.OutOfMemory;
}

fn booleanFromJson(allocator: std.mem.Allocator, value: std.json.Value) CodecError![]const u8 {
    if (value != .bool) return error.InvalidValue;
    return allocator.dupe(u8, if (value.bool) "true" else "false") catch error.OutOfMemory;
}

fn booleanToJson(_: std.mem.Allocator, value: []const u8) CodecError!std.json.Value {
    if (std.mem.eql(u8, value, "t") or std.mem.eql(u8, value, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, value, "f") or std.mem.eql(u8, value, "false")) return .{ .bool = false };
    return error.InvalidValue;
}

pub const text_codec = Codec{
    .queryToPostgres = textFromQuery,
    .jsonToPostgres = textFromJson,
    .postgresToJson = textToJson,
};

pub const integer_codec = Codec{
    .queryToPostgres = integerFromQuery,
    .jsonToPostgres = integerFromJson,
    .postgresToJson = integerToJson,
};

pub const boolean_codec = Codec{
    .queryToPostgres = booleanFromQuery,
    .jsonToPostgres = booleanFromJson,
    .postgresToJson = booleanToJson,
};

pub const common_codecs = .{
    .text = text_codec,
    .integer = integer_codec,
    .boolean = boolean_codec,
};

fn isCodec(comptime T: type) bool {
    return T == Codec;
}

pub fn defineCodecs(comptime type_defs: anytype, comptime codecs: anytype) @TypeOf(codecs) {
    inline for (@typeInfo(@TypeOf(codecs)).@"struct".field_names) |name| {
        if (!@hasField(@TypeOf(type_defs), name))
            @compileError("REST codec '" ++ name ++ "': unknown domain type");
        if (!isCodec(@TypeOf(@field(codecs, name))))
            @compileError("REST codec '" ++ name ++ "': must be a zigma_rest.Codec");
    }
    inline for (@typeInfo(@TypeOf(type_defs)).@"struct".field_names) |name| {
        if (!@hasField(@TypeOf(codecs), name))
            @compileError("domain type '" ++ name ++ "': missing REST codec");
    }
    return codecs;
}

pub const Method = enum { GET, POST, PUT, DELETE, other };

pub const Request = struct {
    method: Method,
    target: []const u8,
    content_type: ?[]const u8 = null,
    body: []const u8 = "",
};

pub const Response = struct {
    status: u16,
    body: []const u8,
    content_type: []const u8 = "application/json",
};

pub const Route = struct {
    path: []const u8,
    methods: [4]Method = .{ .GET, .POST, .PUT, .DELETE },
};

pub const FieldValue = struct {
    name: []const u8,
    value: ?[]const u8,
};

pub const QueryResult = struct {
    allocator: std.mem.Allocator,
    columns: []const []const u8,
    rows: []const []const ?[]const u8,

    pub fn deinit(self: QueryResult) void {
        for (self.columns) |column| self.allocator.free(column);
        self.allocator.free(self.columns);
        for (self.rows) |row| {
            for (row) |value| if (value) |bytes| self.allocator.free(bytes);
            self.allocator.free(row);
        }
        self.allocator.free(self.rows);
    }
};

pub const RepositoryError = error{
    OutOfMemory,
    Conflict,
    Unavailable,
    DatabaseError,
};

pub const Config = struct {
    max_body_bytes: usize = 1024 * 1024,
};

const RawFilter = struct { name: []const u8, value: []const u8 };

fn routeList(comptime entity_defs: anytype) [@typeInfo(@TypeOf(entity_defs)).@"struct".field_names.len]Route {
    const names = @typeInfo(@TypeOf(entity_defs)).@"struct".field_names;
    var result: [names.len]Route = undefined;
    inline for (names, 0..) |name, index| result[index] = .{ .path = "/api/" ++ name };
    return result;
}

fn effectiveNullable(comptime entity: anytype, comptime field_name: []const u8) bool {
    const info = zigma.completeEntity(entity);
    for (info.pk) |pk_name| if (std.mem.eql(u8, pk_name, field_name)) return false;
    return @field(info.fields, field_name).nullable;
}

fn isPrimaryKey(comptime entity: anytype, comptime field_name: []const u8) bool {
    for (zigma.completeEntity(entity).pk) |pk_name|
        if (std.mem.eql(u8, pk_name, field_name)) return true;
    return false;
}

fn decodeHex(byte: u8) ?u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

fn percentDecode(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < encoded.len) {
        if (encoded[index] == '%') {
            if (index + 2 >= encoded.len) return error.InvalidEncoding;
            const high = decodeHex(encoded[index + 1]) orelse return error.InvalidEncoding;
            const low = decodeHex(encoded[index + 2]) orelse return error.InvalidEncoding;
            try output.append(allocator, high * 16 + low);
            index += 3;
        } else {
            try output.append(allocator, if (encoded[index] == '+') ' ' else encoded[index]);
            index += 1;
        }
    }
    if (!std.unicode.utf8ValidateSlice(output.items)) return error.InvalidEncoding;
    return output.toOwnedSlice(allocator);
}

fn parseFilters(allocator: std.mem.Allocator, query: []const u8) ![]RawFilter {
    var filters: std.ArrayList(RawFilter) = .empty;
    errdefer filters.deinit(allocator);
    if (query.len == 0) return filters.toOwnedSlice(allocator);

    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (pair.len == 0) return error.InvalidQuery;
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidQuery;
        const name = try percentDecode(allocator, pair[0..equals]);
        const value = try percentDecode(allocator, pair[equals + 1 ..]);
        for (filters.items) |existing|
            if (std.mem.eql(u8, existing.name, name)) return error.DuplicateFilter;
        try filters.append(allocator, .{ .name = name, .value = value });
    }
    return filters.toOwnedSlice(allocator);
}

fn contentTypeIsJson(value: ?[]const u8) bool {
    const content_type = value orelse return false;
    const end = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    return std.ascii.eqlIgnoreCase(std.mem.trim(u8, content_type[0..end], " \t"), "application/json");
}

fn jsonResponse(allocator: std.mem.Allocator, status: u16, value: anytype) !Response {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    var stringify: std.json.Stringify = .{ .writer = &output.writer };
    try stringify.write(value);
    return .{ .status = status, .body = try output.toOwnedSlice() };
}

fn errorResponse(allocator: std.mem.Allocator, status: u16, code: []const u8, message: []const u8) !Response {
    return jsonResponse(allocator, status, .{ .@"error" = .{ .code = code, .message = message } });
}

fn repositoryErrorResponse(allocator: std.mem.Allocator, err: anyerror) !Response {
    return switch (err) {
        error.Conflict => errorResponse(allocator, 409, "constraint_conflict", "PostgreSQL constraint rejected the operation"),
        error.Unavailable => errorResponse(allocator, 503, "database_unavailable", "Database is unavailable"),
        error.OutOfMemory => error.OutOfMemory,
        else => errorResponse(allocator, 500, "database_error", "Database operation failed"),
    };
}

fn rawFilter(raw: []const RawFilter, name: []const u8) ?[]const u8 {
    for (raw) |filter| if (std.mem.eql(u8, filter.name, name)) return filter.value;
    return null;
}

fn validateFilterNames(comptime entity: anytype, raw: []const RawFilter) bool {
    for (raw) |filter| {
        var found = false;
        inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
            if (std.mem.eql(u8, filter.name, field_name)) {
                found = true;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn buildFilters(
    allocator: std.mem.Allocator,
    comptime entity: anytype,
    comptime codecs: anytype,
    raw: []const RawFilter,
) ![]FieldValue {
    var result: std.ArrayList(FieldValue) = .empty;
    errdefer result.deinit(allocator);
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
        if (rawFilter(raw, field_name)) |raw_value| {
            const domain_type = @field(entity.fields, field_name).type;
            const value = @field(codecs, domain_type).queryToPostgres(allocator, raw_value) catch
                return error.InvalidFilterValue;
            try result.append(allocator, .{ .name = field_name, .value = value });
        }
    }
    return result.toOwnedSlice(allocator);
}

fn objectHasUnknownField(comptime entity: anytype, object: std.json.ObjectMap) bool {
    for (object.keys()) |name| {
        var found = false;
        inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
            if (std.mem.eql(u8, name, field_name)) {
                found = true;
            }
        }
        if (!found) return true;
    }
    return false;
}

fn buildInsertValues(
    allocator: std.mem.Allocator,
    comptime entity: anytype,
    comptime codecs: anytype,
    object: std.json.ObjectMap,
) ![]FieldValue {
    var result: std.ArrayList(FieldValue) = .empty;
    errdefer result.deinit(allocator);
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
        const field_value = object.get(field_name);
        if (field_value == null) {
            if (!effectiveNullable(entity, field_name)) return error.MissingRequiredField;
            try result.append(allocator, .{ .name = field_name, .value = null });
        } else if (field_value.? == .null) {
            if (!effectiveNullable(entity, field_name)) return error.NullNotAllowed;
            try result.append(allocator, .{ .name = field_name, .value = null });
        } else {
            const domain_type = @field(entity.fields, field_name).type;
            const encoded = @field(codecs, domain_type).jsonToPostgres(allocator, field_value.?) catch
                return error.InvalidBodyValue;
            try result.append(allocator, .{ .name = field_name, .value = encoded });
        }
    }
    return result.toOwnedSlice(allocator);
}

fn buildUpdateValues(
    allocator: std.mem.Allocator,
    comptime entity: anytype,
    comptime codecs: anytype,
    object: std.json.ObjectMap,
) ![]FieldValue {
    var result: std.ArrayList(FieldValue) = .empty;
    errdefer result.deinit(allocator);
    inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
        if (object.get(field_name)) |field_value| {
            if (isPrimaryKey(entity, field_name)) return error.PrimaryKeyUpdate;
            if (field_value == .null) {
                if (!effectiveNullable(entity, field_name)) return error.NullNotAllowed;
                try result.append(allocator, .{ .name = field_name, .value = null });
            } else {
                const domain_type = @field(entity.fields, field_name).type;
                const encoded = @field(codecs, domain_type).jsonToPostgres(allocator, field_value) catch
                    return error.InvalidBodyValue;
                try result.append(allocator, .{ .name = field_name, .value = encoded });
            }
        }
    }
    if (result.items.len == 0) return error.EmptyUpdate;
    return result.toOwnedSlice(allocator);
}

fn renderResult(
    response_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    comptime entity: anytype,
    comptime codecs: anytype,
    result: anytype,
    status: u16,
    single: bool,
) !Response {
    const field_names = @typeInfo(@TypeOf(entity.fields)).@"struct".field_names;
    if (result.columns.len != field_names.len) return error.InvalidRepositoryResult;
    inline for (field_names, 0..) |field_name, index| {
        if (!std.mem.eql(u8, result.columns[index], field_name)) return error.InvalidRepositoryResult;
    }
    if (single and result.rows.len != 1) return error.InvalidRepositoryResult;

    var output: std.Io.Writer.Allocating = .init(response_allocator);
    errdefer output.deinit();
    var stringify: std.json.Stringify = .{ .writer = &output.writer };
    if (!single) try stringify.beginArray();
    for (result.rows) |row| {
        if (row.len != field_names.len) return error.InvalidRepositoryResult;
        try stringify.beginObject();
        inline for (field_names, 0..) |field_name, index| {
            try stringify.objectField(field_name);
            if (row[index]) |database_value| {
                const domain_type = @field(entity.fields, field_name).type;
                const json_value = @field(codecs, domain_type).postgresToJson(scratch_allocator, database_value) catch
                    return error.InvalidRepositoryResult;
                try stringify.write(json_value);
            } else {
                try stringify.write(null);
            }
        }
        try stringify.endObject();
    }
    if (!single) try stringify.endArray();
    return .{ .status = status, .body = try output.toOwnedSlice() };
}

fn parseJsonObject(allocator: std.mem.Allocator, body: []const u8) !std.json.Parsed(std.json.Value) {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return error.InvalidJson;
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;
    return parsed;
}

fn requestValidationResponse(allocator: std.mem.Allocator, err: anyerror) !Response {
    return switch (err) {
        error.BodyTooLarge => errorResponse(allocator, 413, "body_too_large", "Request body exceeds the configured limit"),
        error.UnsupportedMediaType => errorResponse(allocator, 415, "unsupported_media_type", "Expected application/json"),
        else => errorResponse(allocator, 400, "invalid_request", "Request fields or values are invalid"),
    };
}

pub fn Api(comptime entity_defs: anytype, comptime codecs: anytype) type {
    const validated = zigma.defineEntities(entity_defs);
    inline for (@typeInfo(@TypeOf(validated)).@"struct".field_names) |entity_name| {
        const entity = @field(validated, entity_name);
        inline for (@typeInfo(@TypeOf(entity.fields)).@"struct".field_names) |field_name| {
            const domain_type = @field(entity.fields, field_name).type;
            if (!@hasField(@TypeOf(codecs), domain_type))
                @compileError("entity '" ++ entity_name ++ "', field '" ++ field_name ++ "': missing REST codec for domain type '" ++ domain_type ++ "'");
            if (!isCodec(@TypeOf(@field(codecs, domain_type))))
                @compileError("REST codec '" ++ domain_type ++ "': must be a zigma_rest.Codec");
        }
    }

    return struct {
        const Self = @This();
        pub const routes = routeList(validated);

        config: Config,

        pub fn init(config: Config) Self {
            return .{ .config = config };
        }

        pub fn handle(
            self: *Self,
            allocator: std.mem.Allocator,
            repository: anytype,
            request: Request,
        ) !Response {
            var scratch = std.heap.ArenaAllocator.init(allocator);
            defer scratch.deinit();
            const scratch_allocator = scratch.allocator();
            if (request.body.len > self.config.max_body_bytes)
                return requestValidationResponse(allocator, error.BodyTooLarge);

            const question = std.mem.indexOfScalar(u8, request.target, '?');
            const path = if (question) |index| request.target[0..index] else request.target;
            const query = if (question) |index| request.target[index + 1 ..] else "";
            if (!std.mem.startsWith(u8, path, "/api/"))
                return errorResponse(allocator, 404, "not_found", "Route not found");
            const entity_path = path[5..];
            if (entity_path.len == 0 or std.mem.indexOfScalar(u8, entity_path, '/') != null)
                return errorResponse(allocator, 404, "not_found", "Route not found");

            inline for (@typeInfo(@TypeOf(validated)).@"struct".field_names) |entity_name| {
                if (std.mem.eql(u8, entity_path, entity_name))
                    return handleEntity(self, allocator, scratch_allocator, repository, request, query, entity_name);
            }
            return errorResponse(allocator, 404, "not_found", "Entity not found");
        }

        fn handleEntity(
            self: *Self,
            response_allocator: std.mem.Allocator,
            scratch_allocator: std.mem.Allocator,
            repository: anytype,
            request: Request,
            query: []const u8,
            comptime entity_name: []const u8,
        ) !Response {
            _ = self;
            const entity = @field(validated, entity_name);
            const raw_filters = parseFilters(scratch_allocator, query) catch |err|
                return requestValidationResponse(response_allocator, err);
            if (!validateFilterNames(entity, raw_filters))
                return requestValidationResponse(response_allocator, error.UnknownFilter);
            const filters = buildFilters(scratch_allocator, entity, codecs, raw_filters) catch |err|
                return requestValidationResponse(response_allocator, err);

            switch (request.method) {
                .GET => {
                    var result = repository.select(scratch_allocator, entity_name, filters) catch |err|
                        return repositoryErrorResponse(response_allocator, err);
                    defer result.deinit();
                    return renderResult(response_allocator, scratch_allocator, entity, codecs, result, 200, false) catch |err| switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => errorResponse(response_allocator, 500, "invalid_repository_result", "Repository returned an invalid row shape"),
                    };
                },
                .POST => {
                    if (query.len != 0) return requestValidationResponse(response_allocator, error.UnexpectedQuery);
                    if (!contentTypeIsJson(request.content_type))
                        return requestValidationResponse(response_allocator, error.UnsupportedMediaType);
                    var parsed = parseJsonObject(scratch_allocator, request.body) catch |err|
                        return requestValidationResponse(response_allocator, err);
                    defer parsed.deinit();
                    if (objectHasUnknownField(entity, parsed.value.object))
                        return requestValidationResponse(response_allocator, error.UnknownBodyField);
                    const values = buildInsertValues(scratch_allocator, entity, codecs, parsed.value.object) catch |err|
                        return requestValidationResponse(response_allocator, err);
                    var result = repository.insert(scratch_allocator, entity_name, values) catch |err|
                        return repositoryErrorResponse(response_allocator, err);
                    defer result.deinit();
                    return renderResult(response_allocator, scratch_allocator, entity, codecs, result, 201, true) catch |err| switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => errorResponse(response_allocator, 500, "invalid_repository_result", "Repository returned an invalid row shape"),
                    };
                },
                .PUT => {
                    if (filters.len == 0) return requestValidationResponse(response_allocator, error.FilterRequired);
                    if (!contentTypeIsJson(request.content_type))
                        return requestValidationResponse(response_allocator, error.UnsupportedMediaType);
                    var parsed = parseJsonObject(scratch_allocator, request.body) catch |err|
                        return requestValidationResponse(response_allocator, err);
                    defer parsed.deinit();
                    if (objectHasUnknownField(entity, parsed.value.object))
                        return requestValidationResponse(response_allocator, error.UnknownBodyField);
                    const values = buildUpdateValues(scratch_allocator, entity, codecs, parsed.value.object) catch |err|
                        return requestValidationResponse(response_allocator, err);
                    var result = repository.update(scratch_allocator, entity_name, values, filters) catch |err|
                        return repositoryErrorResponse(response_allocator, err);
                    defer result.deinit();
                    return renderResult(response_allocator, scratch_allocator, entity, codecs, result, 200, false) catch |err| switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => errorResponse(response_allocator, 500, "invalid_repository_result", "Repository returned an invalid row shape"),
                    };
                },
                .DELETE => {
                    if (filters.len == 0) return requestValidationResponse(response_allocator, error.FilterRequired);
                    var result = repository.delete(scratch_allocator, entity_name, filters) catch |err|
                        return repositoryErrorResponse(response_allocator, err);
                    defer result.deinit();
                    return renderResult(response_allocator, scratch_allocator, entity, codecs, result, 200, false) catch |err| switch (err) {
                        error.OutOfMemory => error.OutOfMemory,
                        else => errorResponse(response_allocator, 500, "invalid_repository_result", "Repository returned an invalid row shape"),
                    };
                },
                .other => return errorResponse(response_allocator, 405, "method_not_allowed", "Allowed methods: GET, POST, PUT, DELETE"),
            }
        }
    };
}
