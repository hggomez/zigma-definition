#!/usr/bin/env python3
"""Comprueba la interfaz pública del build sin ejecutar comandos de aplicación."""

from pathlib import Path
import subprocess
import sys
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


if __name__ == "__main__":
    unittest.main()
