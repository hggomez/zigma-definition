const std = @import("std");
const application = @import("build/application.zig");
const tests = @import("build/tests.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const libpq: tests.LibpqOptions = .{
        .prefix = b.option([]const u8, "libpq-prefix", "Prefix containing libpq include/ and lib/"),
        .include = b.option([]const u8, "libpq-include", "Directory containing libpq-fe.h"),
        .lib = b.option([]const u8, "libpq-lib", "Directory containing the libpq library"),
    };
    const zigma_dep = b.dependency("zigma_definition", .{
        .target = target,
        .optimize = optimize,
        .@"libpq-prefix" = libpq.prefix,
        .@"libpq-include" = libpq.include,
        .@"libpq-lib" = libpq.lib,
    });
    const liquibase_bin = b.option([]const u8, "liquibase-bin", "Path to the Liquibase CLI") orelse
        b.graph.environ_map.get("LIQUIBASE_BIN") orelse "liquibase";
    const app = application.addSteps(b, zigma_dep, .{
        .target = target,
        .optimize = optimize,
        .liquibase_bin = liquibase_bin,
    });

    tests.addSteps(b, zigma_dep, app, target, optimize, libpq);
}
