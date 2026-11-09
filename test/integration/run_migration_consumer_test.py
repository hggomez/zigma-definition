#!/usr/bin/env python3
"""Ejercita la API pública desde un paquete vacío, sin copiar herramientas de Zigma."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("zig")
parser.add_argument("--liquibase")
parser.add_argument("--libpq-prefix")
parser.add_argument("--libpq-include")
parser.add_argument("--libpq-lib")
CONFIG, TEST_ARGS = parser.parse_known_args()
ZIG = CONFIG.zig


class MigrationConsumerBuildTest(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="zigma migration consumer ")
        self.addCleanup(workspace.cleanup)
        self.root = Path(workspace.name).resolve()
        shutil.copyfile(ROOT / "test/integration/migration_consumer_build.zig", self.root / "build.zig")
        shutil.copyfile(ROOT / "test/integration/migration_application.zig", self.root / "postgres.zig")
        (self.root / "build.zig.zon").write_text(
            '.{ .name = .migration_consumer, .version = "0.0.0", '
            '.fingerprint = 0x61be1bea1581417f, '
            '.minimum_zig_version = "0.17.0-dev.1818+7051f8e73", '
            '.dependencies = .{ .zigma_definition = .{ .path = ' + json.dumps(os.path.relpath(ROOT, self.root)) + ' } }, '
            '.paths = .{ "build.zig", "build.zig.zon", "postgres.zig", "db" } }\n'
        )

    def build(self, *args, error=None, env=None):
        config_args = []
        for option in ("libpq-prefix", "libpq-include", "libpq-lib"):
            value = getattr(CONFIG, option.replace("-", "_"))
            if value:
                config_args.append(f"-D{option}={value}")
        if CONFIG.liquibase:
            config_args.append(f"-Dliquibase-bin={CONFIG.liquibase}")
        result = subprocess.run(
            [ZIG, "build", *args, *config_args], cwd=self.root, env=env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=180,
        )
        output = result.stdout + result.stderr
        if error is None:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
            self.assertIn(error, output)
        return output

    def test_empty_consumer_initializes_and_detects_its_own_schema_changes(self):
        help_text = self.build("--help")
        for command in ("init-migrations", "check-schema", "migration", "accept-migration", "apply-migrations"):
            self.assertIn(command, help_text)
        self.assertFalse((self.root / "db").exists())
        self.build("init-migrations")
        snapshot_path = self.root / "db/schema.snapshot.json"
        accepted = snapshot_path.read_bytes()
        self.assertEqual([table["name"] for table in json.loads(accepted)["tables"]], ["products"])
        self.build()
        self.build("check-schema")
        # Este fallo pertenece al guard en compilación, no a una ejecución de check.
        self.build("-Dextended=true", error="PostgreSQL schema differs from db/schema.snapshot.json")
        self.build("check-schema", "-Dextended=true", error="SchemaChanged")
        self.build("migration", "-Dextended=true", "-Dname=add_note")
        draft = self.root / "db/drafts/000002_add_note.sql"
        self.assertIn('ALTER TABLE "products" ADD COLUMN "note" TEXT;', draft.read_text())
        self.assertEqual(snapshot_path.read_bytes(), accepted)
        # El check vuelve a leer el historial aunque no cambió el ejecutable compilado.
        snapshot_path.write_bytes(b"{}")
        self.build("check-schema", error="error:")

    def test_history_root_selects_consumer_files_and_guard(self):
        history = self.root / "custom history"
        history.mkdir()
        option = "-Dhistory-root=custom history"
        self.build("init-migrations", option)
        self.assertFalse((self.root / "db").exists())
        self.assertTrue((history / "db/schema.snapshot.json").exists())
        self.build(option)
        self.build("check-schema", option)
        self.build("migration", "-Dextended=true", option)
        self.assertTrue((history / "db/drafts/000002_add_products_note.sql").exists())

    @unittest.skipIf(os.name == "nt", "The fake Liquibase launcher is a POSIX shell script")
    def test_application_command_uses_the_consumer_changelog_and_guard(self):
        self.build("init-migrations")
        capture = self.root / "liquibase-invocation.txt"
        launcher = self.root / "fake-liquibase"
        launcher.write_text('#!/bin/sh\nprintf "%s\\n" "$PWD" "$@" > "$MIGRATION_TEST_CAPTURE"\n')
        launcher.chmod(0o755)
        env = {key: value for key, value in os.environ.items() if not key.startswith("LIQUIBASE_")}
        env.update(LIQUIBASE_BIN=str(launcher), LIQUIBASE_URL="jdbc:postgresql://localhost/unused",
                   MIGRATION_TEST_CAPTURE=str(capture))
        self.build("apply-migrations", env=env)
        lines = capture.read_text().splitlines()
        self.assertEqual(Path(lines[0]).resolve(), self.root.resolve())
        self.assertEqual(lines[1:], ["--changelog-file=db/changelog-root.yaml", "--default-schema-name=public", "update"])
        capture.unlink()
        self.build("apply-migrations", "-Dextended=true",
                   error="PostgreSQL schema differs from db/schema.snapshot.json", env=env)
        self.assertFalse(capture.exists())

    @unittest.skipUnless(CONFIG.liquibase, "Requires Liquibase, libpq and disposable PostgreSQL")
    def test_acceptance_rejects_wrong_sql_then_accepts_consumer_history(self):
        history = self.root / "custom history"
        history.mkdir()
        option = "-Dhistory-root=custom history"
        self.build("init-migrations", option)
        snapshot = history / "db/schema.snapshot.json"
        original = snapshot.read_bytes()
        self.build("migration", "-Dextended=true", option)
        draft = history / "db/drafts/000002_add_products_note.sql"
        sql = draft.read_text()
        draft.write_text(sql.replace('ADD COLUMN "note"', 'ADD COLUMN "wrong"'))
        self.build("accept-migration", "-Dextended=true", option,
                   error="columns, order, type, or nullability differ")
        self.assertEqual(snapshot.read_bytes(), original)
        self.assertTrue(draft.exists())
        self.assertFalse((history / "db/changes" / draft.name).exists())
        draft.write_text(sql)
        self.build("accept-migration", "-Dextended=true", option)
        self.assertFalse(draft.exists())
        self.assertEqual((history / "db/changes" / draft.name).read_text(), sql)
        current = json.loads(snapshot.read_bytes())
        self.assertEqual([table["name"] for table in current["tables"]], ["products"])
        self.assertEqual(current["tables"][0]["columns"][-1]["name"], "note")
        self.build("-Dextended=true", option)
        self.build("check-schema", "-Dextended=true", option)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *TEST_ARGS])
