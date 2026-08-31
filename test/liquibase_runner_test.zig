const std = @import("std");
const builtin = @import("builtin");
const runner = @import("zigma_liquibase_runner");

const FakeLauncher = struct {
    expected_password: []const u8,
    term: std.process.Child.Term,
    called: bool = false,

    pub fn run(
        self: *FakeLauncher,
        argv: []const []const u8,
        environment: *const std.process.Environ.Map,
    ) runner.Error!std.process.Child.Term {
        self.called = true;
        std.debug.assert(argv.len == 4);
        std.debug.assert(std.mem.eql(u8, "liquibase-test", argv[0]));
        std.debug.assert(std.mem.eql(u8, "--changelog-file=db/changelog-root.yaml", argv[1]));
        std.debug.assert(std.mem.eql(u8, "--default-schema-name=school", argv[2]));
        std.debug.assert(std.mem.eql(u8, "update", argv[3]));
        std.debug.assert(std.mem.eql(u8, "jdbc:postgresql://localhost/zigma", environment.get("LIQUIBASE_COMMAND_URL").?));
        std.debug.assert(std.mem.eql(u8, "zigma", environment.get("LIQUIBASE_COMMAND_USERNAME").?));
        std.debug.assert(std.mem.eql(u8, self.expected_password, environment.get("LIQUIBASE_COMMAND_PASSWORD").?));
        for (argv) |arg| std.debug.assert(std.mem.indexOf(u8, arg, self.expected_password) == null);
        return self.term;
    }
};

test "runner builds a secret-free invocation and accepts success" {
    var fake = FakeLauncher{ .expected_password = "very-secret", .term = .{ .exited = 0 } };
    try runner.updateWith(std.testing.allocator, .{
        .executable = "liquibase-test",
        .changelog_file = "db/changelog-root.yaml",
        .jdbc_url = "jdbc:postgresql://localhost/zigma",
        .username = "zigma",
        .password = "very-secret",
        .schema_name = "school",
    }, &fake);
    try std.testing.expect(fake.called);
}

test "runner converts a non-zero exit into a stable error" {
    var fake = FakeLauncher{ .expected_password = "secret", .term = .{ .exited = 3 } };
    try std.testing.expectError(error.LiquibaseFailed, runner.updateWith(std.testing.allocator, .{
        .executable = "liquibase-test",
        .changelog_file = "db/changelog-root.yaml",
        .jdbc_url = "jdbc:postgresql://localhost/zigma",
        .username = "zigma",
        .password = "secret",
        .schema_name = "school",
    }, &fake));
}

test "runner rejects invalid configuration before launching" {
    var fake = FakeLauncher{ .expected_password = "secret", .term = .{ .exited = 0 } };
    try std.testing.expectError(error.InvalidConfiguration, runner.updateWith(std.testing.allocator, .{
        .changelog_file = "",
        .jdbc_url = "jdbc:postgresql://localhost/zigma",
    }, &fake));
    try std.testing.expect(!fake.called);
}

test "runner reports a missing executable" {
    try std.testing.expectError(error.LiquibaseNotFound, runner.update(std.testing.allocator, .{
        .executable = "/path/that/cannot/contain/liquibase",
        .changelog_file = "db/changelog-root.yaml",
        .jdbc_url = "jdbc:postgresql://localhost/zigma",
    }));
}

test "runtime adapter spawns an external executable directly" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    try runner.update(std.testing.allocator, .{
        .executable = "/usr/bin/true",
        .changelog_file = "db/changelog-root.yaml",
        .jdbc_url = "jdbc:postgresql://localhost/zigma",
    });
}
