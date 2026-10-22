//! EXAMPLE: writes the generated frontend of the aida system into the
//! directory given as the first argument (`zig build frontend-e2e` passes
//! frontend/public): index.html, common.js and one page per entity
//! (<entity>.html, served at /<entity>).

const std = @import("std");
const aida = @import("aida");
const frontend_generator = @import("frontend_generator");

const entity_names = @typeInfo(@TypeOf(aida.entity_defs)).@"struct".field_names;

// Container-level consts are always evaluated in comptime scope (same reason
// as print_ts_backend.zig).
const index_html = frontend_generator.indexHtml("aida", aida.entity_defs);
const pages = blk: {
    var out: [entity_names.len][]const u8 = undefined;
    for (entity_names, 0..) |name, i| {
        out[i] = frontend_generator.entityHtml("aida", aida.type_defs, name, @field(aida.entity_defs, name));
    }
    const frozen = out;
    break :blk frozen;
};

pub fn main(init: std.process.Init) !void {
    // with an allocator: on Windows the arguments are decoded from one string
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    const out_path = args.next() orelse return error.MissingOutputDirectory;

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, out_path);
    var dir = try cwd.openDir(init.io, out_path, .{});
    defer dir.close(init.io);

    try dir.writeFile(init.io, .{ .sub_path = "index.html", .data = index_html });
    try dir.writeFile(init.io, .{ .sub_path = "common.js", .data = frontend_generator.common_js });
    inline for (entity_names, 0..) |name, i| {
        try dir.writeFile(init.io, .{ .sub_path = name ++ ".html", .data = pages[i] });
    }
}
