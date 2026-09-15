const std = @import("std");
const zigma_build = @import("zigma_definition");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zigma_dep = b.dependency("zigma_definition", .{});
    _ = zigma_build.addAppFromDep(b, zigma_dep, .{
        .system_root = b.path("src/system.zig"),
        .widgets_js = b.path("src/widgets.js"),
        .title = "aida",
        .target = target,
        .optimize = optimize,
    });
}
