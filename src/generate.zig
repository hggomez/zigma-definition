//! The generator of a system: a command-line program that writes what the
//! framework generates for whatever module `build.zig` passes as "system"
//! (examples/aida.zig, test/test_system.zig, ...), like src/rules_wasm.zig.
//! Generic: it only reads what any system declares, and each artifact is
//! offered when the system declares what it needs.
//!
//!   generate schema        the DDL                 (type_defs, entity_defs)
//!   generate dml           dml.ts                  (type_defs, entity_defs)
//!   generate dml-tests     dml.test.ts             (type_defs, entity_defs)
//!   generate server        server.ts               (type_defs, entity_defs)
//!   generate frontend DIR  index.html, a page per  (name, type_defs, entity_defs)
//!                          entity, common.js and
//!                          common.css, in DIR
//!   generate rules-ts      rules.ts                (rule_defs)
//!
//! All but `frontend` write to stdout (the build steps capture it to a
//! file). An artifact whose declarations the system lacks is an error.

const std = @import("std");
const system = @import("system");
const sql_generator = @import("sql_generator");
const ts_backend_generator = @import("ts_backend_generator");
const ts_server_generator = @import("ts_server_generator");
const frontend_generator = @import("frontend_generator");
const ts_rules_generator = @import("ts_rules_generator");

const has_entities = @hasDecl(system, "type_defs") and @hasDecl(system, "entity_defs");
const has_name = @hasDecl(system, "name");
const has_rules = @hasDecl(system, "rule_defs");

// Every artifact as a container-level const, null when the system lacks its
// declarations: a container-level const is always evaluated in comptime scope
// (calling a generator from main, a runtime scope, would only yield a runtime
// copy, not comptime-known enough for its internal @field lookups), and the
// branch not taken of a comptime-known `if` is not analyzed.
const schema_ddl: ?[]const u8 = if (has_entities) sql_generator.schemaSql(system.type_defs, system.entity_defs) else null;
const dml_module: ?[]const u8 = if (has_entities) ts_backend_generator.generateTsBackend(system.type_defs, system.entity_defs) else null;
const dml_test_module: ?[]const u8 = if (has_entities) ts_backend_generator.generateTsBackendTests(system.type_defs, system.entity_defs) else null;
const server_module: ?[]const u8 = if (has_entities) ts_server_generator.generateTsServer(system.type_defs, system.entity_defs) else null;
const rules_module: ?[]const u8 = if (has_rules) ts_rules_generator.generateTsRules(system.rule_defs) else null;

const Frontend = struct {
    const entity_names = @typeInfo(@TypeOf(system.entity_defs)).@"struct".field_names;
    const index_html = frontend_generator.indexHtml(system.name, system.entity_defs);
    const pages = blk: {
        var out: [entity_names.len][]const u8 = undefined;
        for (entity_names, 0..) |entity_name, i| {
            out[i] = frontend_generator.entityHtml(system.name, system.type_defs, system.entity_defs, entity_name);
        }
        const frozen = out;
        break :blk frozen;
    };

    // index.html, common.js, common.css and <entity>.html (served at
    // /<entity>) into `out_path`, created if missing.
    fn write(io: std.Io, out_path: []const u8) !void {
        const cwd = std.Io.Dir.cwd();
        try cwd.createDirPath(io, out_path);
        var dir = try cwd.openDir(io, out_path, .{});
        defer dir.close(io);

        try dir.writeFile(io, .{ .sub_path = "index.html", .data = index_html });
        try dir.writeFile(io, .{ .sub_path = "common.js", .data = frontend_generator.common_js });
        try dir.writeFile(io, .{ .sub_path = "common.css", .data = frontend_generator.common_css });
        inline for (entity_names, 0..) |entity_name, i| {
            try dir.writeFile(io, .{ .sub_path = entity_name ++ ".html", .data = pages[i] });
        }
    }
};

const usage = "usage: generate schema | dml | dml-tests | server | frontend DIR | rules-ts\n";

// The message on stderr and exit status 1: a usage error, not a bug (no
// error return trace).
fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}

// `text` to stdout, then `end` ("\n" or ""): the bytes each artifact always had.
fn print(io: std.Io, text: ?[]const u8, comptime end: []const u8, comptime missing: []const u8) !void {
    const t = text orelse return fail("the system declares no {s}\n", .{missing});
    var buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print("{s}" ++ end, .{t});
    try stdout.flush();
}

pub fn main(init: std.process.Init) !void {
    // with an allocator: on Windows the arguments are decoded from one string
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const command = args.next() orelse return fail(usage, .{});

    if (std.mem.eql(u8, command, "schema")) return print(init.io, schema_ddl, "\n", "type_defs and entity_defs");
    if (std.mem.eql(u8, command, "dml")) return print(init.io, dml_module, "\n", "type_defs and entity_defs");
    if (std.mem.eql(u8, command, "dml-tests")) return print(init.io, dml_test_module, "\n", "type_defs and entity_defs");
    if (std.mem.eql(u8, command, "server")) return print(init.io, server_module, "", "type_defs and entity_defs");
    if (std.mem.eql(u8, command, "rules-ts")) return print(init.io, rules_module, "", "rule_defs");
    if (std.mem.eql(u8, command, "frontend")) {
        // a comptime-known condition: Frontend is not analyzed for a system
        // without these declarations
        if (has_entities and has_name) {
            const out_path = args.next() orelse return fail(usage, .{});
            return Frontend.write(init.io, out_path);
        } else return fail("the system declares no name, type_defs and entity_defs\n", .{});
    }
    return fail(usage, .{});
}
