#!/usr/bin/env python3
"""Prueba el workflow de archivos con un consumidor ajeno a AIDA, sin servicios.

accept-files se prueba como operación interna de archivos. La reproducción SQL y
la validación de catálogo siguen siendo responsabilidad de accept-migration.
"""

import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


BASE_TOOL = Path(sys.argv.pop(1)).resolve()
EXTENDED_TOOL = Path(sys.argv.pop(1)).resolve()


class MigrationToolConsumerTest(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix="zigma-consumer-migrations-")
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        self.snapshot = self.root / "db/schema.snapshot.json"
        self.baseline = self.root / "db/changes/000001_baseline.sql"
        self.draft = self.root / "db/drafts/000002_add_products_note.sql"
        self.run_tool(BASE_TOOL, "init")
        self.original_snapshot = self.snapshot.read_bytes()
        self.original_baseline = self.baseline.read_bytes()

    def run_tool(self, executable, *args, error=None):
        result = subprocess.run(
            [str(executable), *args], cwd=self.root, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30,
        )
        output = result.stdout + result.stderr
        if error is None:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
            self.assertIn(error, output)
        return output

    def assert_original_history(self):
        self.assertEqual(self.snapshot.read_bytes(), self.original_snapshot)
        self.assertEqual(self.baseline.read_bytes(), self.original_baseline)
        self.assertEqual(
            sorted(path.name for path in (self.root / "db/changes").iterdir()),
            ["000001_baseline.sql"],
        )

    def test_initialization_uses_only_the_consumer_schema(self):
        snapshot = json.loads(self.original_snapshot)
        self.assertEqual([table["name"] for table in snapshot["tables"]], ["products"])
        self.assertEqual(
            [column["name"] for column in snapshot["tables"][0]["columns"]],
            ["id", "name"],
        )
        self.assertIn('CREATE TABLE "products"', self.baseline.read_text())
        self.assertNotIn("IF NOT EXISTS", self.baseline.read_text())
        self.assertIn("path: changes", (self.root / "db/changelog-root.yaml").read_text())
        self.run_tool(BASE_TOOL, "check")
        self.run_tool(BASE_TOOL, "draft", error="SchemaUnchanged")
        self.run_tool(BASE_TOOL, "init", error="AlreadyInitialized")
        self.assert_original_history()
        self.assertEqual(list((self.root / "db/drafts").iterdir()), [])

    def test_changed_consumer_creates_a_draft_without_advancing_history(self):
        preview = self.run_tool(EXTENDED_TOOL, "check", error="SchemaChanged")
        statement = 'ALTER TABLE "products" ADD COLUMN "note" TEXT;'
        self.assertIn(statement, preview)
        self.assertEqual(list((self.root / "db/drafts").iterdir()), [])
        self.assert_original_history()

        self.run_tool(EXTENDED_TOOL, "draft")
        sql = self.draft.read_text()
        self.assertIn("--changeset zigma:000002_add_products_note", sql)
        self.assertIn(statement, sql)
        self.assertIn(f"from-sha256={hashlib.sha256(self.original_snapshot).hexdigest()}", sql)
        self.assertNotIn("ZIGMA-BLOCKER:", sql)
        self.run_tool(EXTENDED_TOOL, "draft", error="DraftAlreadyExists")
        self.assertEqual(self.draft.read_text(), sql)
        self.assert_original_history()

    def test_file_promotion_rejects_stale_destination_then_advances_consumer_snapshot(self):
        self.run_tool(EXTENDED_TOOL, "draft")
        sql = self.draft.read_bytes()
        self.run_tool(BASE_TOOL, "accept-files", error="StaleDraft")
        self.assertEqual(self.draft.read_bytes(), sql)
        self.assert_original_history()

        self.run_tool(EXTENDED_TOOL, "accept-files")
        self.assertFalse(self.draft.exists())
        self.assertEqual((self.root / "db/changes" / self.draft.name).read_bytes(), sql)
        self.assertEqual(self.baseline.read_bytes(), self.original_baseline)
        current = self.snapshot.read_bytes()
        self.assertIn(f"to-sha256={hashlib.sha256(current).hexdigest()}", sql.decode())
        snapshot = json.loads(current)
        self.assertEqual([table["name"] for table in snapshot["tables"]], ["products"])
        note = snapshot["tables"][0]["columns"][-1]
        self.assertEqual(note["name"], "note")
        self.assertTrue(note["nullable"])
        self.run_tool(EXTENDED_TOOL, "check")
        self.run_tool(BASE_TOOL, "check", error="SchemaChanged")

    def test_file_promotion_preserves_unresolved_draft_and_history(self):
        self.run_tool(EXTENDED_TOOL, "draft")
        sql = self.draft.read_text() + "\n-- ZIGMA-BLOCKER: pending review\n"
        self.draft.write_text(sql)
        self.run_tool(EXTENDED_TOOL, "accept-files", error="DraftHasBlockers")
        self.assertEqual(self.draft.read_text(), sql)
        self.assert_original_history()


if __name__ == "__main__":
    unittest.main()
