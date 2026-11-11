#!/usr/bin/env python3
"""Comprueba el classpath enviado a Liquibase por los comandos reales de AIDA."""
import argparse
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("zig")
parser.add_argument("--libpq-prefix")
parser.add_argument("--libpq-include")
parser.add_argument("--libpq-lib")
CONFIG, TEST_ARGS = parser.parse_known_args()


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return str(listener.getsockname()[1])


class AidaClasspathTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workspace = tempfile.TemporaryDirectory(prefix="zigma aida classpath ")
        cls.addClassCleanup(workspace.cleanup)
        cls.workspace = Path(workspace.name).resolve()
        cls.root = cls.workspace / "project with spaces"
        cls.application = cls.root / "examples/aida"
        cls.application.mkdir(parents=True)
        cls.outside = cls.workspace / "outside project"
        cls.outside.mkdir()
        # Usa el build real con fuentes compartidas y artefactos locales al fixture.
        # El historial original solo se lee; no se ejecuta Liquibase ni una conexión DB.
        for name in ("build.zig", "build.zig.zon"):
            shutil.copyfile(ROOT / name, cls.root / name)
            shutil.copyfile(ROOT / "examples/aida" / name, cls.application / name)
        for name in ("build", "src", "test"):
            (cls.root / name).symlink_to(ROOT / name, target_is_directory=True)
        for name in ("build", "src", "db"):
            (cls.application / name).symlink_to(ROOT / "examples/aida" / name,
                                              target_is_directory=True)
        cls.libs = cls.root / "liquibase_libs"
        cls.libs.mkdir()
        cls.driver = cls.libs / "postgresql-fixture.jar"
        cls.capture = cls.workspace / "liquibase invocation.json"
        cls.liquibase = cls.workspace / "fake liquibase"
        cls.liquibase.write_text(
            '#!/usr/bin/env python3\n'
            'import json, os, pathlib, sys\n'
            'pathlib.Path(os.environ["AIDA_TEST_CAPTURE"]).write_text(json.dumps({\n'
            '    "cwd": os.getcwd(), "args": sys.argv[1:],\n'
            '    "classpath": os.environ.get("LIQUIBASE_CLASSPATH"),\n'
            '}))\n'
            'sys.exit(23)\n'
        )
        cls.liquibase.chmod(0o755)

    def setUp(self):
        # El CLI simulado captura el entorno: no necesita un JAR ejecutable.
        self.driver.write_bytes(b"fixture: PostgreSQL JDBC driver path")
        self.capture.unlink(missing_ok=True)

    def build(self, *args, cwd=None, env=None):
        flags = []
        for name in ("libpq-prefix", "libpq-include", "libpq-lib"):
            if value := getattr(CONFIG, name.replace("-", "_")):
                flags.append(f"-D{name}={value}")
        return subprocess.run(
            [CONFIG.zig, "build", "--build-file", str(self.application / "build.zig"),
             *args, "-j4", *flags], cwd=cwd or self.application, env=env,
            capture_output=True, text=True, timeout=180,
        )

    def invoke(self, command="run", cwd=None, classpath=None):
        env = {key: value for key, value in os.environ.items()
               if not key.startswith("LIQUIBASE_")}
        env.update(
            LIQUIBASE_BIN=str(self.liquibase), AIDA_TEST_CAPTURE=str(self.capture),
            LIQUIBASE_URL="jdbc:postgresql://127.0.0.1:1/unused",
            DATABASE_URL="postgresql://127.0.0.1:1/unused",
            HTTP_ADDRESS="127.0.0.1", HTTP_PORT=free_port(), FRONTEND_PORT=free_port(),
            ZIGMA_STARTUP_TIMEOUT="5",
        )
        while env["HTTP_PORT"] == env["FRONTEND_PORT"]:
            env["FRONTEND_PORT"] = free_port()
        if classpath is not None:
            env["LIQUIBASE_CLASSPATH"] = classpath
        result = self.build(command, cwd=cwd, env=env)
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, output)
        self.assertIn("LiquibaseFailed", output)
        self.assertNotIn("ConnectionFailed", output)
        self.assertTrue(self.capture.is_file(), output)
        invocation = json.loads(self.capture.read_text())
        self.capture.unlink()
        self.assertEqual(Path(invocation["cwd"]).resolve(), self.application)
        self.assertEqual(invocation["args"], ["--changelog-file=db/changelog-root.yaml",
                                              "--default-schema-name=public", "update"])
        return invocation["classpath"]

    def test_run_finds_driver_from_any_working_directory(self):
        for cwd in (self.root, self.application, self.outside):
            with self.subTest(cwd=cwd.relative_to(self.workspace)):
                self.assertEqual(self.invoke(cwd=cwd), str(self.driver))

    def test_backend_command_also_finds_driver(self):
        self.assertEqual(self.invoke("run-backend", self.outside), str(self.driver))

    def test_default_build_installs_the_complete_application(self):
        prefix = self.workspace / "custom installation"
        result = self.build("--prefix", str(prefix))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for name in ("aida-backend", "aida-launcher"):
            self.assertTrue((prefix / "bin" / name).is_file(), f"Falta el ejecutable {name}")
        for name in ("frontend.wasm", "index.html", "main.js", "title.js", "widgets.js"):
            self.assertTrue((prefix / "frontend" / name).is_file(), f"Falta {name}")

    def test_application_driver_takes_precedence_over_repository_driver(self):
        local_libs = self.application / "liquibase_libs"
        local_libs.mkdir()
        driver = local_libs / "postgresql-local.jar"
        driver.write_bytes(b"application JDBC fixture")
        try:
            self.assertEqual(self.invoke("run-backend", self.outside), str(driver))
        finally:
            driver.unlink()
            local_libs.rmdir()

    def test_explicit_classpath_takes_precedence(self):
        explicit = str(self.workspace / "custom drivers/postgresql-explicit.jar")
        self.assertEqual(self.invoke(cwd=self.outside, classpath=explicit), explicit)

    def test_driver_changes_are_detected_without_cleaning_cache(self):
        self.assertEqual(self.invoke("run-backend"), str(self.driver))
        replacement = self.libs / "postgresql-replacement.jar"
        self.driver.rename(replacement)
        try:
            self.assertEqual(self.invoke("run-backend"), str(replacement))
            replacement.unlink()
            self.assertIsNone(self.invoke("run-backend"))
            self.driver.write_bytes(b"installed again")
            self.assertEqual(self.invoke("run-backend"), str(self.driver))
        finally:
            replacement.unlink(missing_ok=True)

    def test_multiple_jars_use_absolute_paths_and_ignore_other_entries(self):
        extra = self.libs / "additional-library.jar"
        ignored = self.libs / "README.txt"
        directory = self.libs / "directory.jar"
        extra.write_bytes(b"additional fixture JAR")
        ignored.write_text("not a JAR")
        directory.mkdir()
        try:
            expected = os.pathsep.join(sorted((str(extra), str(self.driver))))
            self.assertEqual(self.invoke("run-backend", self.outside), expected)
        finally:
            extra.unlink()
            ignored.unlink()
            directory.rmdir()

    def test_missing_local_driver_preserves_liquibase_default_discovery(self):
        self.driver.unlink()
        self.libs.rmdir()
        try:
            self.assertIsNone(self.invoke("run-backend", self.outside))
        finally:
            self.libs.mkdir()


if __name__ == "__main__":
    unittest.main(argv=[__file__, *TEST_ARGS])
