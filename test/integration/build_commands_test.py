#!/usr/bin/env python3
"""Comprueba la interfaz pública del build sin ejecutar comandos de aplicación."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ZIG = sys.argv.pop(1) if len(sys.argv) > 1 else "zig"


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

    def test_migrations_only_command_is_published(self):
        self.assertIn("apply-migrations", self.steps)

    def test_direct_ddl_startup_is_not_public(self):
        self.assertNotIn("run-postgres-bootstrap", self.steps)

    def test_old_migration_command_has_no_alias(self):
        self.assertNotIn("run-postgres-liquibase-bootstrap", self.steps)

    def test_existing_supported_commands_remain_available(self):
        expected = {
            "run-aida", "run-aida-rest", "check-aida", "check-aida-rest",
            "test", "test-model", "test-json", "test-aida-launcher",
            "test-postgres", "test-rest-postgres", "test-migrations",
            "check-schema", "migration", "accept-migration",
            "init-migrations",
        }
        self.assertFalse(expected - self.steps, f"Comandos faltantes: {expected - self.steps}")

    def test_aida_has_frontend_commands_without_an_in_memory_backend(self):
        result = subprocess.run(
            [ZIG, "build", "--help"], cwd=ROOT / "examples/aida", text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        section = result.stdout.split("Steps:\n", 1)[1].split("\n\n", 1)[0]
        steps = {line.split()[0] for line in section.splitlines() if line.strip()}
        self.assertTrue({"frontend", "test-frontend"} <= steps)
        self.assertFalse({"testing-backend", "test-backend"} & steps,
                         "El consumidor todavía publica comandos del backend retirado")


class FrontendConsumerTest(unittest.TestCase):
    def test_default_build_installs_only_frontend_without_a_rest_adapter(self):
        with tempfile.TemporaryDirectory(prefix="zigma frontend consumer ") as directory:
            root = Path(directory).resolve()
            (root / "build.zig.zon").write_text(
                '.{ .name = .migration_consumer, .version = "0.0.0", '
                '.fingerprint = 0x61be1bea1581417f, '
                '.dependencies = .{ .zigma_definition = .{ .path = '
                + json.dumps(os.path.relpath(ROOT, root)) + ' } }, '
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


if __name__ == "__main__":
    unittest.main()
