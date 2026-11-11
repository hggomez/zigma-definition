#!/usr/bin/env python3
"""Comprueba la interfaz pública del build sin ejecutar comandos de aplicación."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ZIG = sys.argv.pop(1) if len(sys.argv) > 1 else "zig"


def copy_framework_without_examples(destination):
    """Paquete mínimo que conserva el build real, sin el ejemplo ni sus snapshots."""
    destination.mkdir()
    for name in ("build.zig", "build.zig.zon"):
        shutil.copyfile(ROOT / name, destination / name)
    shutil.copytree(ROOT / "build", destination / "build")
    (destination / "src").symlink_to(ROOT / "src", target_is_directory=True)


class BuildCommandsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Un error de compilación del build es un error del test, no el rojo
        # esperado por la presencia o ausencia de un comando.
        result = subprocess.run(
            [ZIG, "build", "--help"], cwd=ROOT, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        if result.returncode:
            raise RuntimeError(f"Falló zig build --help:\n{result.stderr}")
        section = result.stdout.split("Steps:\n", 1)[1].split("\n\n", 1)[0]
        cls.steps = {line.split()[0] for line in section.splitlines() if line.strip()}

    def test_local_suite_is_published(self):
        self.assertIn("test-local", self.steps)

    def test_framework_does_not_publish_application_commands(self):
        application_steps = {
            "run-aida", "run-aida-rest", "check-aida", "check-aida-rest",
            "run", "run-backend", "check-schema", "migration",
            "accept-migration", "init-migrations", "apply-migrations",
        }
        self.assertFalse(application_steps & self.steps,
                         f"Comandos de aplicación en la raíz: {application_steps & self.steps}")

    def test_direct_ddl_startup_is_not_public(self):
        self.assertNotIn("run-postgres-bootstrap", self.steps)

    def test_old_migration_command_has_no_alias(self):
        self.assertNotIn("run-postgres-liquibase-bootstrap", self.steps)

    def test_framework_test_commands_remain_available(self):
        expected = {
            "test", "test-model", "test-json", "test-aida-launcher",
            "test-postgres", "test-rest-postgres", "test-migrations",
            "test-runtime", "test-runtime-backend",
        }
        self.assertFalse(expected - self.steps, f"Comandos faltantes: {expected - self.steps}")

    def test_aida_owns_application_and_migration_commands(self):
        result = subprocess.run(
            [ZIG, "build", "--help"], cwd=ROOT / "examples/aida", text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        section = result.stdout.split("Steps:\n", 1)[1].split("\n\n", 1)[0]
        steps = {line.split()[0] for line in section.splitlines() if line.strip()}
        expected = {
            "frontend", "test-frontend", "run", "run-backend", "check", "check-backend",
            "check-schema", "migration", "accept-migration", "init-migrations", "apply-migrations",
        }
        self.assertFalse(expected - steps, f"Comandos faltantes en AIDA: {expected - steps}")
        self.assertFalse({"testing-backend", "test-backend"} & steps,
                         "El consumidor todavía publica comandos del backend retirado")


class FrontendConsumerTest(unittest.TestCase):
    def test_default_build_installs_only_frontend_without_a_rest_adapter(self):
        with tempfile.TemporaryDirectory(prefix="zigma frontend consumer ") as directory:
            root = Path(directory).resolve()
            framework = root / "framework without examples"
            copy_framework_without_examples(framework)
            (root / "build.zig.zon").write_text(
                '.{ .name = .migration_consumer, .version = "0.0.0", '
                '.fingerprint = 0x61be1bea1581417f, '
                '.dependencies = .{ .zigma_definition = .{ .path = '
                + json.dumps(os.path.relpath(framework, root)) + ' } }, '
                '.paths = .{ "build.zig", "build.zig.zon", "system.zig" } }\n'
            )
            (root / "build.zig").write_text('''
const std = @import("std");
const zigma = @import("zigma_definition");
pub fn build(b: *std.Build) void {
    const dep = b.dependency("zigma_definition", .{});
    _ = zigma.addAppFromDep(b, dep, .{
        .system_root = b.path("system.zig"),
        .title = "Independent inventory",
    });
}
''')
            (root / "system.zig").write_text('''
const zigma = @import("zigma");
pub const type_defs = zigma.common_type_defs;
const definition = .{
    .fields = zigma.record(type_defs, .{ .id = .{ .type = "integer" } }),
    .pk = .{"id"},
};
pub const entity_defs = zigma.defineEntities(.{
    .products = .{ .Type = zigma.Entity(type_defs, definition), .definition = definition },
});
''')
            prefix = root / "custom installation"
            result = subprocess.run(
                [ZIG, "build", "--prefix", str(prefix)], cwd=root, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            frontend = prefix / "frontend"
            for filename in ("index.html", "main.js", "api-config.js", "title.js", "frontend.wasm"):
                self.assertTrue((frontend / filename).is_file(), filename)
            self.assertEqual((frontend / "frontend.wasm").read_bytes()[:8], b"\x00asm\x01\x00\x00\x00")
            self.assertIn("Independent inventory", (frontend / "title.js").read_text())
            self.assertFalse((prefix / "bin").exists(), "El frontend no debe instalar un backend implícito")


class FrameworkModulesTest(unittest.TestCase):
    def test_default_framework_build_does_not_require_aida_or_its_snapshot(self):
        with tempfile.TemporaryDirectory(prefix="zigma standalone framework ") as directory:
            framework = Path(directory).resolve() / "framework without examples"
            copy_framework_without_examples(framework)
            result = subprocess.run(
                [ZIG, "build"], cwd=framework, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((framework / "zig-out/bin").exists())

    def test_framework_registration_preserves_application_owned_modules(self):
        with tempfile.TemporaryDirectory(prefix="zigma framework modules ") as directory:
            root = Path(directory).resolve()
            (root / "build").mkdir()
            (root / "build/modules.zig").symlink_to(ROOT / "build/modules.zig")
            (root / "src").symlink_to(ROOT / "src", target_is_directory=True)
            # No contiene examples/: este build solo usa el registro del framework.
            # Los nombres del dominio pertenecen al consumidor y no deben colisionar.
            for name in ("aida", "aida_rest", "aida_postgres"):
                (root / f"{name}.zig").write_text(f'pub const owner = "consumer:{name}";\n')
            (root / "build.zig").write_text('''
const std = @import("std");
const framework = @import("build/modules.zig");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const names = .{ "aida", "aida_rest", "aida_postgres" };
    inline for (names) |name| {
        _ = b.addModule(name, .{
            .root_source_file = b.path(name ++ ".zig"),
            .target = target,
            .optimize = optimize,
        });
    }
    const modules = framework.create(b, target, optimize);
    const probe = b.createModule(.{
        .root_source_file = b.path("probe.zig"),
        .target = target,
        .optimize = optimize,
    });
    probe.addImport("zigma", modules.zigma);
    inline for (names) |name| probe.addImport(name, b.modules.get(name).?);
    const tests = b.addTest(.{ .root_module = probe });
    const run = b.addRunArtifact(tests);
    b.default_step.dependOn(&run.step);
}
''')
            (root / "probe.zig").write_text('''
const std = @import("std");
test "framework and application modules coexist without example sources" {
    try std.testing.expect(@hasDecl(@import("zigma"), "Framework"));
    try std.testing.expectEqualStrings("consumer:aida", @import("aida").owner);
    try std.testing.expectEqualStrings("consumer:aida_rest", @import("aida_rest").owner);
    try std.testing.expectEqualStrings("consumer:aida_postgres", @import("aida_postgres").owner);
}
''')
            result = subprocess.run(
                [ZIG, "build"], cwd=root, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
