//! Creating an instance of the framework: the system comes from the command
//! line, so this file names none.
//!
//!   zig build up   -Dsystem=examples/<name>.zig [-Dseed=examples/<name>_seed.sql]
//!   zig build down -Dsystem=examples/<name>.zig
//!   zig build print-schema -Dsystem=...      zig build create-database -Dsystem=...
//!
//! The tests (with an example system) are a package of their own,
//! test/build.zig, which reuses the pub functions of this file through its
//! dependency on this package: `zig build --build-file test/build.zig test`.
//! Every path these functions resolve is relative to the `b` they get: pass
//! them this package's builder (the dependency's), so the generated files,
//! .env and the compose stacks are the ones at the root.

const std = @import("std");

/// The modules of the framework: zigma and its generators.
pub const Framework = struct {
    zigma: *std.Build.Module,
    zig_type_map_sql: *std.Build.Module,
    sql_generator: *std.Build.Module,
    zig_type_map_ts: *std.Build.Module,
    ts_backend_generator: *std.Build.Module,
    ts_server_generator: *std.Build.Module,
    frontend_generator: *std.Build.Module,
    ts_rules_generator: *std.Build.Module,
};

pub fn addFramework(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Framework {
    const zigma = b.addModule("zigma", .{
        .root_source_file = b.path("src/zigma.zig"),
        .target = target,
        .optimize = optimize,
    });
    const zig_type_map_sql = b.addModule("zig_type_map_sql", .{
        .root_source_file = b.path("src/zig_type_map_sql.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sql_generator = b.addModule("sql_generator", .{
        .root_source_file = b.path("src/sql_generator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma },
            .{ .name = "zig_type_map_sql", .module = zig_type_map_sql },
        },
    });
    const zig_type_map_ts = b.addModule("zig_type_map_ts", .{
        .root_source_file = b.path("src/zig_type_map_ts.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ts_backend_generator = b.addModule("ts_backend_generator", .{
        .root_source_file = b.path("src/ts_backend_generator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma },
            .{ .name = "zig_type_map_ts", .module = zig_type_map_ts },
        },
    });
    const ts_server_generator = b.addModule("ts_server_generator", .{
        .root_source_file = b.path("src/ts_server_generator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma },
            .{ .name = "zig_type_map_ts", .module = zig_type_map_ts },
            .{ .name = "ts_backend_generator", .module = ts_backend_generator },
        },
    });
    const frontend_generator = b.addModule("frontend_generator", .{
        .root_source_file = b.path("src/frontend_generator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = zigma },
            .{ .name = "zig_type_map_ts", .module = zig_type_map_ts },
            .{ .name = "ts_backend_generator", .module = ts_backend_generator },
        },
    });
    const ts_rules_generator = b.addModule("ts_rules_generator", .{
        .root_source_file = b.path("src/ts_rules_generator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zig_type_map_ts", .module = zig_type_map_ts },
            .{ .name = "ts_backend_generator", .module = ts_backend_generator },
        },
    });
    return .{
        .zigma = zigma,
        .zig_type_map_sql = zig_type_map_sql,
        .sql_generator = sql_generator,
        .zig_type_map_ts = zig_type_map_ts,
        .ts_backend_generator = ts_backend_generator,
        .ts_server_generator = ts_server_generator,
        .frontend_generator = frontend_generator,
        .ts_rules_generator = ts_rules_generator,
    };
}

/// The framework's modules as a dependency on this package registered them
/// (its `build` always calls `addFramework`), for a package that depends on
/// this one: test/build.zig.
pub fn frameworkOf(dep: *std.Build.Dependency) Framework {
    return .{
        .zigma = dep.module("zigma"),
        .zig_type_map_sql = dep.module("zig_type_map_sql"),
        .sql_generator = dep.module("sql_generator"),
        .zig_type_map_ts = dep.module("zig_type_map_ts"),
        .ts_backend_generator = dep.module("ts_backend_generator"),
        .ts_server_generator = dep.module("ts_server_generator"),
        .frontend_generator = dep.module("frontend_generator"),
        .ts_rules_generator = dep.module("ts_rules_generator"),
    };
}

/// A system described with zigma (its SSOT file), as a module.
pub fn addSystemModule(b: *std.Build, framework: Framework, source: std.Build.LazyPath, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = source,
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zigma", .module = framework.zigma },
        },
    });
}

/// The generator of `system` (src/generate.zig with it as "system"): it
/// writes what the framework generates for that system; each step runs it
/// with what to generate (`schema`, `dml`, `frontend DIR`, ...).
pub fn addGenerate(
    b: *std.Build,
    name: []const u8,
    system: *std.Build.Module,
    framework: Framework,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/generate.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "system", .module = system },
                .{ .name = "sql_generator", .module = framework.sql_generator },
                .{ .name = "ts_backend_generator", .module = framework.ts_backend_generator },
                .{ .name = "ts_server_generator", .module = framework.ts_server_generator },
                .{ .name = "frontend_generator", .module = framework.frontend_generator },
                .{ .name = "ts_rules_generator", .module = framework.ts_rules_generator },
            },
        }),
    });
}

/// What is generated for a system and written into the repo (all
/// gitignored): .env, backend/src/*.ts and frontend/public. One node each,
/// shared by every step that needs it.
pub const Generated = struct {
    generate: *std.Build.Step.Compile,
    /// The DDL, captured.
    schema_sql: std.Build.LazyPath,
    /// `.env` at the root, read by every `docker compose`: the system's name
    /// as SYSTEM_NAME, which docker-compose.yml interpolates into its
    /// container, database and volume names.
    write_env: *std.Build.Step,
    /// backend/src/dml.ts and dml.test.ts: the backend image is built from
    /// the committed backend/ package.
    write_ts_backend: *std.Build.Step,
    /// backend/src/server.ts.
    write_ts_server: *std.Build.Step,
    /// frontend/public: the pages the frontend image serves.
    write_frontend: *std.Build.Step,
};

/// The writes into the repo are owned by `writer`, the root package of the
/// build (only the root package may update source files), and their paths
/// are `to_root` (from the writer's directory to this package's) plus the
/// file: `addGenerated(b, b, "", ...)` here, `addGenerated(root, b, "../",
/// ...)` from test/build.zig.
pub fn addGenerated(b: *std.Build, writer: *std.Build, to_root: []const u8, generate: *std.Build.Step.Compile) Generated {
    const run_generate_env = b.addRunArtifact(generate);
    run_generate_env.addArg("env");
    const write_env = writer.addUpdateSourceFiles();
    write_env.addCopyFileToSource(run_generate_env.captureStdOut(.{}), b.fmt("{s}.env", .{to_root}));

    const run_generate_schema = b.addRunArtifact(generate);
    run_generate_schema.addArg("schema");

    const run_generate_dml = b.addRunArtifact(generate);
    run_generate_dml.addArg("dml");
    const run_generate_dml_tests = b.addRunArtifact(generate);
    run_generate_dml_tests.addArg("dml-tests");
    const write_ts_backend = writer.addUpdateSourceFiles();
    write_ts_backend.addCopyFileToSource(run_generate_dml.captureStdOut(.{}), b.fmt("{s}backend/src/dml.ts", .{to_root}));
    write_ts_backend.addCopyFileToSource(run_generate_dml_tests.captureStdOut(.{}), b.fmt("{s}backend/src/dml.test.ts", .{to_root}));

    const run_generate_server = b.addRunArtifact(generate);
    run_generate_server.addArg("server");
    const write_ts_server = writer.addUpdateSourceFiles();
    write_ts_server.addCopyFileToSource(run_generate_server.captureStdOut(.{}), b.fmt("{s}backend/src/server.ts", .{to_root}));

    const write_frontend = b.addRunArtifact(generate);
    write_frontend.addArgs(&.{ "frontend", "frontend/public" });
    write_frontend.setCwd(b.path("."));
    write_frontend.has_side_effects = true;

    return .{
        .generate = generate,
        .schema_sql = run_generate_schema.captureStdOut(.{}),
        .write_env = &write_env.step,
        .write_ts_backend = &write_ts_backend.step,
        .write_ts_server = &write_ts_server.step,
        .write_frontend = &write_frontend.step,
    };
}

/// A compose stack: `docker compose` with its files. `test` is the base file
/// alone (the test stack); `instance` puts docker-compose.instance.yml on
/// top (the system's own project, other ports).
pub const Compose = struct {
    argv: []const []const u8,
    generated: Generated,

    pub fn testStack(generated: Generated) Compose {
        return .{ .argv = &.{ "docker", "compose" }, .generated = generated };
    }

    pub fn instance(generated: Generated) Compose {
        return .{ .argv = &.{ "docker", "compose", "-f", "docker-compose.yml", "-f", "docker-compose.instance.yml" }, .generated = generated };
    }

    /// `docker compose <args>`, after .env is written.
    pub fn run(self: Compose, b: *std.Build, args: []const []const u8) *std.Build.Step.Run {
        const cmd = b.addSystemCommand(self.argv);
        cmd.addArgs(args);
        cmd.setCwd(b.path("."));
        cmd.step.dependOn(self.generated.write_env);
        return cmd;
    }

    /// psql inside the postgres service, as the user and on the database the
    /// container was created with (its POSTGRES_USER / POSTGRES_DB, which
    /// docker-compose.yml takes from SYSTEM_NAME): no name of the system
    /// here. `args` go to psql ("$@"). `exec -T`: stdin without a TTY, so a
    /// schema can be piped in.
    pub fn psql(self: Compose, b: *std.Build, args: []const []const u8) *std.Build.Step.Run {
        const cmd = self.run(b, &.{ "exec", "-T", "postgres", "sh", "-c", "exec psql -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" \"$@\"", "psql" });
        cmd.addArgs(args);
        return cmd;
    }

    /// Postgres up (the `--wait` flag blocks on its healthcheck, so this is
    /// race-free even on first-time init) and the generated schema piped
    /// into it. No Postgres driver needed: psql runs inside the container.
    pub fn applySchema(self: Compose, b: *std.Build) *std.Build.Step {
        const postgres_up = self.run(b, &.{ "up", "-d", "--wait", "postgres" });
        const apply = self.psql(b, &.{});
        apply.setStdIn(.{ .lazy_path = self.generated.schema_sql });
        apply.step.dependOn(&postgres_up.step);
        return &apply.step;
    }

    /// The whole stack up with a fresh database: regenerate the backend and
    /// the frontend, build the images, bring the frontend up (and the backend
    /// and Postgres with it, waiting for their healthchecks), then reset the
    /// database (drop the schema, apply the generated DDL, load the seed if
    /// there is one). It keeps running until `down`.
    pub fn upWithFreshDatabase(self: Compose, b: *std.Build, seed: ?std.Build.LazyPath) *std.Build.Step {
        const build_images = self.run(b, &.{ "build", "backend", "frontend" });
        build_images.step.dependOn(self.generated.write_ts_backend);
        build_images.step.dependOn(self.generated.write_ts_server);
        build_images.step.dependOn(self.generated.write_frontend);

        const up = self.run(b, &.{ "up", "-d", "--wait", "frontend" });
        up.step.dependOn(&build_images.step);

        const reset = self.psql(b, &.{ "-v", "ON_ERROR_STOP=1", "-q", "-c", "DROP SCHEMA public CASCADE; CREATE SCHEMA public;" });
        reset.step.dependOn(&up.step);

        const apply = self.psql(b, &.{ "-v", "ON_ERROR_STOP=1", "-q" });
        apply.setStdIn(.{ .lazy_path = self.generated.schema_sql });
        apply.step.dependOn(&reset.step);

        const s = seed orelse return &apply.step;
        const load_seed = self.psql(b, &.{ "-v", "ON_ERROR_STOP=1", "-q" });
        load_seed.setStdIn(.{ .lazy_path = s });
        load_seed.step.dependOn(&apply.step);
        return &load_seed.step;
    }

    /// Stop and remove the stack's containers and network. The volume stays:
    /// `upWithFreshDatabase` resets it anyway.
    pub fn down(self: Compose, b: *std.Build) *std.Build.Step {
        return &self.run(b, &.{"down"}).step;
    }
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const system_path = b.option([]const u8, "system", "The system to run: its SSOT file, described with zigma (e.g. examples/<name>.zig)");
    const seed_path = b.option([]const u8, "seed", "Optional: SQL rows loaded into the database after the schema, by `up`");

    const print_schema_step = b.step("print-schema", "Print the DDL generated for the system (-Dsystem)");
    const create_database_step = b.step("create-database", "Start the system's Postgres via Docker, then generate and apply its schema (-Dsystem)");
    const up_step = b.step("up", "Bring the system's stack up (frontend on 8081) with a fresh database and the seed rows if given (-Dsystem, -Dseed)");
    const down_step = b.step("down", "Stop and remove the system's stack (-Dsystem)");

    // The framework's modules (`zigma`, the generators) are registered with or
    // without a system: a package that depends on this one imports them.
    const framework = addFramework(b, target, optimize);

    const path = system_path orelse {
        const fail = b.addFail("no system: pass its SSOT file with -Dsystem=<path>, e.g. -Dsystem=examples/<name>.zig");
        for ([_]*std.Build.Step{ print_schema_step, create_database_step, up_step, down_step }) |step| step.dependOn(&fail.step);
        return;
    };

    const system = addSystemModule(b, framework, b.path(path), target, optimize);
    const generated = addGenerated(b, b, "", addGenerate(b, "generate", system, framework, target, optimize));
    const instance = Compose.instance(generated);

    const run_print_schema = b.addRunArtifact(generated.generate);
    run_print_schema.addArg("schema");
    print_schema_step.dependOn(&run_print_schema.step);

    create_database_step.dependOn(instance.applySchema(b));
    up_step.dependOn(instance.upWithFreshDatabase(b, if (seed_path) |s| b.path(s) else null));
    down_step.dependOn(instance.down(b));
}
