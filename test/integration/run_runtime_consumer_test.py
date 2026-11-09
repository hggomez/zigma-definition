#!/usr/bin/env python3
"""Contrato de extracción del runtime: paquete propio, sin entradas copiadas de AIDA."""
import argparse
import http.client
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("zig")
parser.add_argument("--with-libpq", action="store_true")
parser.add_argument("--liquibase")
parser.add_argument("--libpq-prefix")
parser.add_argument("--libpq-include")
parser.add_argument("--libpq-lib")
CONFIG, TEST_ARGS = parser.parse_known_args()


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return str(listener.getsockname()[1])


class RuntimeConsumerTest(unittest.TestCase):
    def setUp(self):
        workspace = tempfile.TemporaryDirectory(prefix="zigma runtime consumer ")
        self.addCleanup(workspace.cleanup)
        self.root = Path(workspace.name).resolve()
        self.application = self.root / "application workspace"
        self.application.mkdir()
        for source, destination in (
            ("runtime_consumer_build.zig", "build.zig"),
            ("runtime_contract.zig", "contract.zig"),
            ("runtime_rest.zig", "rest.zig"),
            ("runtime_postgres.zig", "postgres.zig"),
        ):
            shutil.copyfile(ROOT / "test/integration" / source, self.root / destination)
        # Conserva la identidad del paquete fixture de migraciones; se usa en un build separado.
        (self.root / "build.zig.zon").write_text(
            '.{ .name = .migration_consumer, .version = "0.0.0", '
            '.fingerprint = 0x61be1bea1581417f, '
            '.minimum_zig_version = "0.17.0-dev.1818+7051f8e73", '
            '.dependencies = .{ .zigma_definition = .{ .path = '
            + json.dumps(os.path.relpath(ROOT, self.root)) + ' } }, '
            '.paths = .{ "build.zig", "build.zig.zon", "contract.zig", '
            '"rest.zig", "postgres.zig", "application workspace" } }\n'
        )

    def build(self, *args, error=None, env=None):
        flags = []
        for name in ("libpq-prefix", "libpq-include", "libpq-lib"):
            if value := getattr(CONFIG, name.replace("-", "_")):
                flags.append(f"-D{name}={value}")
        result = subprocess.run(
            [CONFIG.zig, "build", *args, *flags], cwd=self.root, env=env,
            capture_output=True, text=True, timeout=180,
        )
        output = result.stdout + result.stderr
        if error is None:
            self.assertEqual(result.returncode, 0, output)
        else:
            self.assertNotEqual(result.returncode, 0, output)
            self.assertIn(error, output)
        return output

    def test_launcher_is_independent_of_libpq_and_accepted_snapshot(self):
        help_text = self.build("--help")
        for command in ("run", "run-backend", "check-backend", "install-launcher"):
            self.assertIn(command, help_text)
        self.build("install-launcher")
        launcher = self.root / "zig-out/bin/inventory-launcher"
        self.assertTrue(launcher.is_file())
        self.assertFalse((self.application / "db").exists())
        # Reutiliza las pruebas de señales, timeouts, HTTP y supervisión del lanzador.
        result = subprocess.run(
            [sys.executable, str(ROOT / "test/integration/run_launcher_test.py"), str(launcher)],
            capture_output=True, text=True, timeout=90,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_runtime_composes_with_the_consumers_migration_history(self):
        self.build("init-migrations")
        self.assertFalse((self.root / "db").exists())
        snapshot = json.loads((self.application / "db/schema.snapshot.json").read_text())
        self.assertEqual([table["name"] for table in snapshot["tables"]], ["products"])
        self.build("check-schema")

    @unittest.skipUnless(CONFIG.with_libpq, "Requires libpq to compile the PostgreSQL backend")
    def test_backend_guard_and_migration_failure(self):
        self.build("init-migrations")
        # Api no declara ContextProvider: también comprueba el caso ValidationContext == void.
        self.build("check-backend")
        self.build("check-backend", "-Dextended=true",
                   error="PostgreSQL schema differs from db/schema.snapshot.json")
        capture = self.root / "liquibase-invocation.txt"
        liquibase = self.root / "fake-liquibase"
        liquibase.write_text('#!/bin/sh\nprintf "%s\\n" "$PWD" "$@" > "$RUNTIME_TEST_CAPTURE"\nexit 23\n')
        liquibase.chmod(0o755)
        env = {key: value for key, value in os.environ.items() if not key.startswith("LIQUIBASE_")}
        env.update(
            LIQUIBASE_BIN=str(liquibase), LIQUIBASE_URL="jdbc:postgresql://127.0.0.1:1/unused",
            DATABASE_URL="postgresql://127.0.0.1:1/unused", RUNTIME_TEST_CAPTURE=str(capture),
            HTTP_ADDRESS="127.0.0.1", ZIGMA_STARTUP_TIMEOUT="5",
        )
        for command in ("run-backend", "run"):
            with self.subTest(command=command):
                env["HTTP_PORT"] = free_port()
                env["FRONTEND_PORT"] = free_port()
                while env["FRONTEND_PORT"] == env["HTTP_PORT"]:
                    env["FRONTEND_PORT"] = free_port()
                output = self.build(command, error="LiquibaseFailed", env=env)
                self.assertNotIn("ConnectionFailed", output)
                lines = capture.read_text().splitlines()
                self.assertEqual(Path(lines[0]).resolve(), self.application)
                self.assertEqual(lines[1:], ["--changelog-file=db/changelog-root.yaml",
                                            "--default-schema-name=public", "update"])
                capture.unlink()
                for name in ("HTTP_PORT", "FRONTEND_PORT"):
                    with socket.socket() as listener:
                        listener.bind(("127.0.0.1", int(env[name])))
        self.build("run-backend", "-Dextended=true", env=env,
                   error="PostgreSQL schema differs from db/schema.snapshot.json")
        self.assertFalse(capture.exists())

    @unittest.skipUnless(CONFIG.liquibase, "Requires Liquibase, libpq and disposable PostgreSQL")
    def test_real_migrations_frontend_and_persistent_crud(self):
        self.build("init-migrations")
        self.build("install-runtime")
        container = "zigma-runtime-" + self.root.name.rsplit(" ", 1)[-1]
        self.addCleanup(subprocess.run, ["docker", "rm", "--force", container],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        subprocess.run(
            ["docker", "run", "--detach", "--rm", "--name", container,
             "--publish", "127.0.0.1::5432", "--env", "POSTGRES_DB=inventory",
             "--env", "POSTGRES_PASSWORD=postgres", "postgres:18.4-alpine3.24"],
            check=True, capture_output=True, timeout=90,
        )
        deadline = time.monotonic() + 60
        while subprocess.run(
            ["docker", "exec", container, "pg_isready", "--host", "127.0.0.1",
             "--username", "postgres", "--dbname", "inventory"],
            capture_output=True, timeout=10,
        ).returncode:
            self.assertLess(time.monotonic(), deadline, "PostgreSQL did not become ready")
            time.sleep(0.2)
        port = subprocess.check_output(["docker", "port", container, "5432/tcp"],
                                       text=True, timeout=10).strip().rsplit(":", 1)[-1]
        env = {key: value for key, value in os.environ.items() if not key.startswith("LIQUIBASE_")}
        env.update(
            LIQUIBASE_BIN=CONFIG.liquibase,
            LIQUIBASE_URL=f"jdbc:postgresql://127.0.0.1:{port}/inventory",
            LIQUIBASE_USERNAME="postgres", LIQUIBASE_PASSWORD="postgres",
            DATABASE_URL=f"postgresql://postgres:postgres@127.0.0.1:{port}/inventory",
            HTTP_ADDRESS="127.0.0.1", HTTP_PORT=free_port(), FRONTEND_PORT=free_port(),
            ZIGMA_STARTUP_TIMEOUT="120",
        )
        while env["FRONTEND_PORT"] == env["HTTP_PORT"]:
            env["FRONTEND_PORT"] = free_port()
        backend = self.root / "zig-out/bin/inventory-backend"
        launcher = self.root / "zig-out/bin/inventory-launcher"
        frontend = self.root / "zig-out/frontend"

        def request(port, path, method="GET", value=None):
            connection = http.client.HTTPConnection("127.0.0.1", int(port), timeout=1)
            try:
                connection.request(method, path, body=json.dumps(value) if value is not None else None,
                                   headers={"Content-Type": "application/json"})
                response = connection.getresponse()
                return response.status, response.read()
            finally:
                connection.close()

        def stop(process):
            if process.poll() is None:
                process.send_signal(signal.SIGINT)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)

        # El segundo arranque usa el mismo historial/base: prueba idempotencia y persistencia.
        for full in (True, False):
            with self.subTest(full=full):
                log_path = self.root / f"runtime-{full}.log"
                with log_path.open("w") as log:
                    command = [str(launcher), str(backend), str(frontend)] if full else [str(backend)]
                    process = subprocess.Popen(command, cwd=self.application, env=env,
                                               stdout=log, stderr=subprocess.STDOUT)
                    self.addCleanup(stop, process)
                    try:
                        ready_port = env["FRONTEND_PORT"] if full else env["HTTP_PORT"]
                        ready_path = "/" if full else "/api/products"
                        deadline = time.monotonic() + 120
                        while True:
                            self.assertIsNone(process.poll(), log_path.read_text())
                            try:
                                if request(ready_port, ready_path)[0] == 200:
                                    break
                            except (OSError, http.client.HTTPException):
                                pass
                            self.assertLess(time.monotonic(), deadline, log_path.read_text())
                            time.sleep(0.1)
                        if full:
                            self.assertIn(b"Inventory", request(ready_port, "/")[1])
                            self.assertIn(env["HTTP_PORT"].encode(), request(ready_port, "/api-config.js")[1])
                            self.assertEqual(request(env["HTTP_PORT"], "/api/products"), (200, b"[]"))
                            status, body = request(env["HTTP_PORT"], "/api/products", "POST",
                                                   {"id": 1, "name": "Notebook"})
                            self.assertEqual(status, 201, body)
                        else:
                            status, body = request(env["HTTP_PORT"], "/api/products")
                            self.assertEqual(status, 200, body)
                            self.assertEqual(json.loads(body), [{"id": 1, "name": "Notebook"}])
                            status, body = request(env["HTTP_PORT"], "/api/products?id=1", "PUT", {"name": "Pencil"})
                            self.assertEqual(status, 200, body)
                            self.assertEqual(json.loads(request(env["HTTP_PORT"], "/api/products")[1]),
                                             [{"id": 1, "name": "Pencil"}])
                            status, body = request(env["HTTP_PORT"], "/api/products?id=1", "DELETE")
                            self.assertEqual(status, 200, body)
                            self.assertEqual(request(env["HTTP_PORT"], "/api/products"), (200, b"[]"))
                    finally:
                        stop(process)
                for name in ("HTTP_PORT", "FRONTEND_PORT"):
                    with socket.socket() as listener:
                        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                        listener.bind(("127.0.0.1", int(env[name])))


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], *TEST_ARGS])
