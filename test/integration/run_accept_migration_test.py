#!/usr/bin/env python3
"""Contrato del coordinador Zig de aceptación con procesos simulados, sin servicios."""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest


parser = argparse.ArgumentParser()
parser.add_argument("acceptor")
CONFIG, TEST_ARGS = parser.parse_known_args()
COMMAND = [str(Path(CONFIG.acceptor).resolve())]

FAKE_PROCESS = r'''
import json
import os
from pathlib import Path
import sys
import time

args = sys.argv[1:]
name = Path(sys.argv[0]).name
root = Path(os.environ["ACCEPT_TEST_ROOT"])
scenario = os.environ.get("ACCEPT_TEST_SCENARIO", "")
event = {"args": args, "cwd": os.getcwd()}
if name == "docker":
    if args[0] == "run":
        stage = "docker-run"
    elif args[0] == "exec":
        stage = "ready" if "pg_isready" in args else "schema"
    elif args[0] == "port":
        stage = "port"
    elif args[0] == "rm":
        stage = "cleanup"
    else:
        raise RuntimeError(args)
elif name == "liquibase":
    stage = "liquibase"
    event["url"] = os.environ.get("LIQUIBASE_COMMAND_URL")
    event["username"] = os.environ.get("LIQUIBASE_COMMAND_USERNAME")
    event["password"] = os.environ.get("LIQUIBASE_COMMAND_PASSWORD")
    search = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--search-path="))
    changelog = next(arg.split("=", 1)[1] for arg in args if arg.startswith("--changelog-file="))
    candidates = [Path(changelog)] + [Path(part) / changelog for part in search.split(",")]
    path = next(path for path in candidates if path.is_file())
    event["changelog"] = path.read_text()
    event["temporary_directory"] = str(path.parent)
elif name == "validator":
    stage = "validator"
    event["url"] = os.environ.get("DATABASE_URL")
    event["schema"] = os.environ.get("ZIGMA_ACTUAL_SCHEMA")
else:
    assert name == "migration-tool" and args == ["accept-files"], (name, args)
    stage = "accept"
event["stage"] = stage
with (root / "events.jsonl").open("a") as log:
    log.write(json.dumps(event) + "\n")
if scenario == stage or (scenario == "never-ready" and stage == "ready"):
    print("simulated failure: " + stage, file=sys.stderr)
    sys.exit(23)
if stage == "docker-run":
    (root / "container").write_text(args[args.index("--name") + 1])
    print("fake-container-id")
elif stage == "port":
    print("127.0.0.1:54321")
elif stage == "liquibase" and scenario == "interrupt":
    time.sleep(60)
elif stage == "accept":
    project = Path.cwd()
    draft = next((project / "db/drafts").glob("*.sql"))
    draft.rename(project / "db/changes" / draft.name)
    (project / "db/schema.snapshot.json").write_text("accepted snapshot\n")
elif stage == "cleanup":
    (root / "container").unlink(missing_ok=True)
'''


@unittest.skipIf(os.name == "nt", "Process-group interruption contract targets macOS/Linux")
class AcceptMigrationTest(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="zigma acceptance ")
        self.addCleanup(workspace.cleanup)
        self.root = Path(workspace.name).resolve()
        self.project = self.root / "consumer history"
        self.bin = self.root / "fake executables"
        self.bin.mkdir()
        self.temporary = self.root / "temporary files"
        self.temporary.mkdir()
        for name in ("docker", "liquibase", "validator", "migration-tool"):
            executable = self.bin / name
            executable.write_text(f"#!{sys.executable}\n" + FAKE_PROCESS)
            executable.chmod(0o755)
        for name in ("changes", "drafts"):
            (self.project / "db" / name).mkdir(parents=True, exist_ok=True)
        self.snapshot = self.project / "db/schema.snapshot.json"
        self.snapshot.write_text("original snapshot\n")
        self.baseline = self.project / "db/changes/000001_baseline.sql"
        self.baseline.write_text("-- baseline\n")
        (self.project / "db/changelog-root.yaml").write_text("databaseChangeLog: []\n")
        self.draft = self.project / "db/drafts/000002_add_note.sql"
        self.draft.write_text('--liquibase formatted sql\nALTER TABLE "products" ADD COLUMN "note" TEXT;\n')
        self.original_draft = self.draft.read_bytes()

    def events(self):
        log = self.root / "events.jsonl"
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def start(self, scenario="", tools_only=False):
        env = {key: value for key, value in os.environ.items() if not key.startswith("LIQUIBASE_")}
        env.update(
            PATH=str(self.bin) + ("" if tools_only else os.pathsep + os.environ.get("PATH", "")),
            TMPDIR=str(self.temporary),
            ACCEPT_TEST_ROOT=str(self.root),
            ACCEPT_TEST_SCENARIO=scenario,
            ZIGMA_MIGRATION_STARTUP_TIMEOUT="1" if scenario == "never-ready" else "10",
        )
        process = subprocess.Popen(
            [*COMMAND, str(self.bin / "migration-tool"), str(self.bin / "validator"),
             str(self.bin / "liquibase"), str(self.project)],
            cwd=self.root, env=env, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, start_new_session=True,
        )
        self.addCleanup(self.kill_group, process)
        return process

    @staticmethod
    def kill_group(process):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if process.poll() is None:
            process.communicate(timeout=5)

    def finish(self, process, timeout=5):
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            self.kill_group(process)
            self.fail("El coordinador no terminó dentro del plazo; debe cancelar y limpiar los recursos")
        return process.returncode, stdout + stderr

    def assert_unchanged(self):
        self.assertEqual(self.snapshot.read_text(), "original snapshot\n")
        self.assertEqual(self.baseline.read_text(), "-- baseline\n")
        self.assertEqual(self.draft.read_bytes(), self.original_draft)
        self.assertEqual([path.name for path in self.baseline.parent.iterdir()], [self.baseline.name])
        self.assertNotIn("accept", [event["stage"] for event in self.events()])

    def assert_cleaned(self):
        self.assertFalse((self.root / "container").exists(), "Quedó un contenedor sin eliminar")
        self.assertEqual(list(self.temporary.iterdir()), [], "Quedaron archivos temporales")
        events = self.events()
        self.assertIn("cleanup", [event["stage"] for event in events])
        for event in events:
            if "temporary_directory" in event:
                self.assertFalse(Path(event["temporary_directory"]).exists())

    def assert_success(self, tools_only=False):
        code, output = self.finish(self.start(tools_only=tools_only))
        self.assertEqual(code, 0, output)
        events = self.events()
        stages = [event["stage"] for event in events]
        for before, after in (("docker-run", "ready"), ("ready", "liquibase"),
                              ("liquibase", "validator"), ("validator", "accept"), ("accept", "cleanup")):
            self.assertLess(stages.index(before), stages.index(after), stages)
        liquibase = next(event for event in events if event["stage"] == "liquibase")
        self.assertEqual(liquibase["url"], "jdbc:postgresql://127.0.0.1:54321/zigma_test")
        self.assertEqual(liquibase["username"], "postgres")
        self.assertEqual(liquibase["password"], "postgres")
        self.assertIn("--default-schema-name=actual", liquibase["args"])
        self.assertEqual(liquibase["args"][-1], "update")
        self.assertIn("db/changelog-root.yaml", liquibase["changelog"])
        self.assertIn("db/drafts/" + self.draft.name, liquibase["changelog"])
        validator = next(event for event in events if event["stage"] == "validator")
        self.assertEqual(validator["url"], "postgresql://postgres:postgres@127.0.0.1:54321/zigma_test")
        self.assertEqual(validator["schema"], "actual")
        for event in events:
            if event["stage"] in ("liquibase", "validator", "accept"):
                self.assertEqual(Path(event["cwd"]), self.project)
        self.assertFalse(self.draft.exists())
        self.assertEqual((self.baseline.parent / self.draft.name).read_bytes(), self.original_draft)
        self.assertEqual(self.snapshot.read_text(), "accepted snapshot\n")
        self.assertEqual(self.baseline.read_text(), "-- baseline\n")
        self.assert_cleaned()

    def test_accepts_only_after_replay_and_validation_with_spaced_paths(self):
        self.assert_success()

    def test_acceptance_does_not_require_shell_utilities_on_path(self):
        self.assert_success(tools_only=True)

    def test_liquibase_failure_preserves_history_and_cleans_resources(self):
        code, output = self.finish(self.start("liquibase"))
        self.assertNotEqual(code, 0, output)
        self.assertNotIn("validator", [event["stage"] for event in self.events()])
        self.assert_unchanged()
        self.assert_cleaned()

    def test_validator_failure_preserves_history_and_cleans_resources(self):
        code, output = self.finish(self.start("validator"))
        self.assertNotEqual(code, 0, output)
        self.assert_unchanged()
        self.assert_cleaned()

    def test_unresolved_blockers_never_start_external_processes(self):
        self.draft.write_bytes(self.original_draft + b"-- ZIGMA-BLOCKER: pending review\n")
        self.original_draft = self.draft.read_bytes()
        code, output = self.finish(self.start())
        self.assertNotEqual(code, 0, output)
        self.assertEqual(self.events(), [])
        self.assert_unchanged()

    def test_multiple_drafts_never_start_external_processes(self):
        self.draft.with_name("000003_other.sql").write_text("-- another draft\n")
        code, output = self.finish(self.start())
        self.assertNotEqual(code, 0, output)
        self.assertEqual(self.events(), [])
        self.assert_unchanged()

    def test_readiness_timeout_preserves_history_and_cleans_resources(self):
        code, output = self.finish(self.start("never-ready"))
        self.assertNotEqual(code, 0, output)
        self.assertIn("StartupTimeout", output)
        self.assert_unchanged()
        self.assert_cleaned()

    def assert_interruption(self, sig):
        process = self.start("interrupt")
        deadline = time.monotonic() + 5
        while not any(event["stage"] == "liquibase" for event in self.events()):
            self.assertIsNone(process.poll(), "El coordinador terminó antes de ejecutar Liquibase")
            self.assertLess(time.monotonic(), deadline, "Liquibase no se inició")
            time.sleep(0.02)
        process.send_signal(sig)
        code, output = self.finish(process)
        self.assertNotEqual(code, 0, output)
        self.assert_unchanged()
        self.assert_cleaned()

    def test_termination_during_liquibase_cleans_without_accepting(self):
        self.assert_interruption(signal.SIGTERM)

    def test_ctrl_c_during_liquibase_cleans_without_accepting(self):
        self.assert_interruption(signal.SIGINT)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *TEST_ARGS])
