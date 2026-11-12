#!/usr/bin/env python3
"""Composición real del consumidor; todas las mutaciones usan paquetes y bases descartables."""
import argparse
from http.client import HTTPConnection, HTTPException
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tarfile
import tempfile
import time
import unittest

APPLICATION = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("zig")
parser.add_argument("--framework-root", type=Path, default=APPLICATION.parents[1])
parser.add_argument("--with-libpq", action="store_true")
parser.add_argument("--libpq-prefix")
parser.add_argument("--libpq-include")
parser.add_argument("--libpq-lib")
parser.add_argument("--liquibase")
parser.add_argument("--jdbc-classpath")
CONFIG, TEST_ARGS = parser.parse_known_args()
ENTITIES = {"productos", "productos_precios", "clientes", "carritos", "productos_carritos",
            "descuentos_cantidad", "tickets", "tickets_productos"}


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def stop(process):
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=10)


class ApplicationTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = tempfile.TemporaryDirectory(prefix="supermercado published packages ")
        cls.addClassCleanup(directory.cleanup)
        cls.packages = Path(directory.name).resolve()
        cache = Path(os.environ.get("ZIG_GLOBAL_CACHE_DIR", cls.packages / "cache")).resolve()
        environment = {**os.environ, "ZIG_GLOBAL_CACHE_DIR": str(cache)}
        cls.template = cls.packages / "framework"
        for source, target in ((CONFIG.framework_root.resolve(), cls.template),
                               (APPLICATION, cls.template / "examples/supermercado")):
            result = subprocess.run([CONFIG.zig, "fetch", str(source)], cwd=cls.packages, env=environment,
                                    capture_output=True, text=True, timeout=180)
            if result.returncode:
                raise RuntimeError(result.stderr)
            package_hash = result.stdout.strip()
            with tarfile.open(cache / "p" / f"{package_hash}.tar.gz") as package:
                package.extractall(cls.packages / "unpacked", filter="data")
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.move(cls.packages / "unpacked" / package_hash, target)

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="supermercado application test ")
        self.addCleanup(directory.cleanup)
        self.workspace = Path(directory.name).resolve()
        self.framework = self.workspace / "framework"
        shutil.copytree(self.template, self.framework)
        self.application = self.framework / "examples/supermercado"
        self.prefix = self.workspace / "installed application"
        self.outside = self.workspace / "outside directory"
        self.outside.mkdir()

    def build(self, *args, native=False, cwd=None, env=None):
        flags = []
        if native:
            for name in ("libpq-prefix", "libpq-include", "libpq-lib"):
                if value := getattr(CONFIG, name.replace("-", "_")):
                    flags.append(f"-D{name}={value}")
        return subprocess.run(
            [CONFIG.zig, "build", "--build-file", str(self.application / "build.zig"), *args, *flags],
            cwd=cwd or self.application, env=env, capture_output=True, text=True, timeout=240,
        )

    def succeeds(self, *args, **kwargs):
        result = self.build(*args, **kwargs)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def snapshot(self):
        path = self.application / "db/schema.snapshot.json"
        self.assertTrue(path.is_file(), "Falta el snapshot aceptado y publicado de Supermercado")
        return path

    def test_public_commands(self):
        """El consumidor ofrece frontend, backend, migraciones y sus suites sin importar AIDA."""
        output = self.succeeds("--help")
        section = output.split("Steps:\n", 1)[1].split("\n\n", 1)[0]
        steps = {line.split()[0] for line in section.splitlines() if line.strip()}
        expected = {"frontend", "run", "run-backend", "check", "check-backend", "init-migrations",
                    "check-schema", "migration", "accept-migration", "apply-migrations",
                    "test", "test-rest", "test-frontend", "test-local", "test-application"}
        self.assertFalse(expected - steps, f"Comandos faltantes: {expected - steps}")
        self.assertFalse((self.framework / "examples/aida").exists())

    def test_published_layout(self):
        """El paquete conserva módulos, composición, adaptador REST e historial propios."""
        required = ("build/modules.zig", "build/application.zig", "build/tests.zig", "src/rest.zig",
                    "db/schema.snapshot.json", "db/changelog-root.yaml", "db/changes/000001_baseline.sql")
        missing = [name for name in required if not (self.application / name).is_file()]
        self.assertFalse(missing, f"Archivos ausentes del paquete: {missing}")

    def test_frontend_installation_and_real_wasm(self):
        """Frontend instala únicamente la página y ejecuta los seis casos del WASM real sin libpq."""
        self.succeeds("frontend", "--prefix", str(self.prefix))
        frontend = self.prefix / "frontend"
        for name in ("index.html", "main.js", "api-config.js", "title.js", "frontend.wasm"):
            self.assertTrue((frontend / name).is_file(), name)
        self.assertFalse((self.prefix / "bin").exists())
        self.assertIn("Supermercado", (frontend / "title.js").read_text())
        result = subprocess.run(
            ["node", "--experimental-vm-modules", str(self.application / "test/integration/frontend_test.mjs"),
             str(frontend / "frontend.wasm"), str(frontend / "main.js")],
            capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_accepted_history_matches_the_eight_entities(self):
        """El historial inicial contiene las ocho tablas y coincide con el snapshot generado."""
        snapshot = json.loads(self.snapshot().read_text())
        self.assertEqual({table["name"] for table in snapshot["tables"]}, ENTITIES)
        self.succeeds("check-schema")
        baseline = self.application / "db/changes/000001_baseline.sql"
        self.assertTrue(baseline.is_file(), "Falta el baseline del consumidor")
        sql = baseline.read_text()
        self.assertTrue(sql.startswith("--liquibase formatted sql"))
        self.assertEqual(sql.count("CREATE TABLE"), 8)
        self.assertIn("TIMESTAMPTZ", sql)
        self.assertIn('REFERENCES "productos_precios" ("id_producto", "id")', sql)

    def test_history_can_be_initialized_without_services(self):
        """Init-migrations reconstruye el historial propio desde cero sin necesitar PostgreSQL."""
        history = self.application / "db"
        if history.exists():
            shutil.rmtree(history)
        self.succeeds("init-migrations", cwd=self.outside)
        self.assertEqual({table["name"] for table in json.loads(self.snapshot().read_text())["tables"]}, ENTITIES)
        self.succeeds("check-schema")
        self.assertFalse((self.outside / "db").exists())
        self.assertFalse((self.framework / "db").exists())

    def test_stale_snapshot_is_rejected_without_overwriting_history(self):
        """Check-schema rechaza diferencias y deja intacto el historial aceptado."""
        snapshot = self.snapshot()
        self.succeeds("check-schema")
        stale = snapshot.read_text().replace('"sql_type":"TEXT"', '"sql_type":"BIGINT"', 1)
        self.assertNotEqual(stale, snapshot.read_text())
        snapshot.write_text(stale)
        result = self.build("check-schema")
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(snapshot.read_text(), stale)
        # Generar el frontend no aplica ni acepta una migración.
        self.succeeds("frontend", "--prefix", str(self.prefix))
        self.assertEqual(snapshot.read_text(), stale)

    @unittest.skipUnless(CONFIG.with_libpq, "Requiere libpq; ejecutar con --with-libpq")
    def test_default_build_installs_frontend_backend_and_launcher(self):
        """El build completo instala el frontend y los dos ejecutables de Supermercado."""
        self.succeeds("--prefix", str(self.prefix), native=True)
        for name in ("supermercado-backend", "supermercado-launcher"):
            self.assertTrue((self.prefix / "bin" / name).is_file(), name)
        self.assertTrue((self.prefix / "frontend/frontend.wasm").is_file())

    @unittest.skipUnless(CONFIG.with_libpq, "Requiere libpq; ejecutar con --with-libpq")
    def test_backend_guard_rejects_stale_snapshot(self):
        """El backend falla en compilación si el modelo difiere del snapshot aceptado."""
        snapshot = self.snapshot()
        self.succeeds("check-backend", native=True)
        snapshot.write_text(snapshot.read_text().replace('"sql_type":"TEXT"', '"sql_type":"BIGINT"', 1))
        result = self.build("check-backend", native=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PostgreSQL schema differs from db/schema.snapshot.json", result.stdout + result.stderr)

    @unittest.skipUnless(CONFIG.with_libpq, "Requiere libpq; ejecutar con --with-libpq")
    def test_startup_uses_own_history_and_driver_from_another_directory(self):
        """Run y run-backend resuelven historial y driver propios y propagan fallos de Liquibase."""
        self.succeeds("check-backend", native=True)
        capture = self.workspace / "liquibase invocation.json"
        liquibase = self.workspace / "fake liquibase"
        liquibase.write_text('#!/usr/bin/env python3\nimport json, os, pathlib, sys\n'
                            'pathlib.Path(os.environ["TEST_CAPTURE"]).write_text(json.dumps({'
                            '"cwd":os.getcwd(),"args":sys.argv[1:],"classpath":os.environ.get("LIQUIBASE_CLASSPATH")}))\n'
                            'sys.exit(23)\n')
        liquibase.chmod(0o755)
        libs = self.application / "liquibase_libs"
        libs.mkdir()
        driver = libs / "postgresql.jar"
        driver.write_bytes(b"driver fixture: Liquibase is simulated")
        for step, explicit in (("run", None), ("run-backend", None), ("run-backend", "explicit classpath")):
            with self.subTest(step=step, classpath=explicit):
                api_port, frontend_port = free_port(), free_port()
                while api_port == frontend_port:
                    frontend_port = free_port()
                env = {key: value for key, value in os.environ.items() if not key.startswith("LIQUIBASE_")}
                env.update(LIQUIBASE_BIN=str(liquibase), TEST_CAPTURE=str(capture),
                           LIQUIBASE_URL="jdbc:postgresql://127.0.0.1:1/unused", DATABASE_URL="postgresql://127.0.0.1:1/unused",
                           HTTP_ADDRESS="127.0.0.1", HTTP_PORT=str(api_port), FRONTEND_PORT=str(frontend_port), ZIGMA_STARTUP_TIMEOUT="5")
                if explicit:
                    env["LIQUIBASE_CLASSPATH"] = explicit
                result = self.build(step, native=True, cwd=self.outside, env=env)
                output = result.stdout + result.stderr
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("LiquibaseFailed", output)
                self.assertNotIn("ConnectionFailed", output)
                self.assertTrue(capture.is_file(), output)
                invocation = json.loads(capture.read_text())
                self.assertEqual(Path(invocation["cwd"]).resolve(), self.application)
                self.assertEqual(invocation["args"], ["--changelog-file=db/changelog-root.yaml", "--default-schema-name=public", "update"])
                self.assertEqual(invocation["classpath"], explicit or str(driver))
                capture.unlink()
                for port in (api_port, frontend_port):
                    with socket.socket() as listener:
                        listener.bind(("127.0.0.1", port))

    @unittest.skipUnless(CONFIG.liquibase and CONFIG.with_libpq, "Requiere --liquibase, libpq y Docker")
    def test_real_migrations_crud_relations_and_persistence(self):
        """Liquibase crea el MER y el runtime persiste CRUD, restricciones y fechas al reiniciar."""
        self.succeeds("--prefix", str(self.prefix), native=True)
        backend = self.prefix / "bin/supermercado-backend"
        launcher = self.prefix / "bin/supermercado-launcher"
        self.assertTrue(backend.is_file() and launcher.is_file(), "Faltan los ejecutables del runtime")
        container = "supermercado-test-" + self.workspace.name.rsplit(" ", 1)[-1]
        self.addCleanup(subprocess.run, ["docker", "rm", "--force", container], capture_output=True, timeout=30)
        subprocess.run(["docker", "run", "--detach", "--rm", "--name", container,
                        "--publish", "127.0.0.1::5432", "--env", "POSTGRES_DB=supermercado",
                        "--env", "POSTGRES_PASSWORD=postgres", "postgres:18.4-alpine3.24"],
                       check=True, capture_output=True, timeout=90)
        deadline = time.monotonic() + 60
        while subprocess.run(["docker", "exec", container, "pg_isready", "-h", "127.0.0.1", "-U", "postgres", "-d", "supermercado"],
                             capture_output=True, timeout=10).returncode:
            self.assertLess(time.monotonic(), deadline, "PostgreSQL no quedó listo")
            time.sleep(0.2)
        published = subprocess.check_output(["docker", "port", container, "5432/tcp"], text=True).strip().rsplit(":", 1)[-1]
        api_port, frontend_port = free_port(), free_port()
        while api_port == frontend_port:
            frontend_port = free_port()
        env = {key: value for key, value in os.environ.items() if not key.startswith("LIQUIBASE_")}
        env.update(DATABASE_URL=f"postgresql://postgres:postgres@127.0.0.1:{published}/supermercado",
                   LIQUIBASE_BIN=CONFIG.liquibase, LIQUIBASE_URL=f"jdbc:postgresql://127.0.0.1:{published}/supermercado",
                   LIQUIBASE_USERNAME="postgres", LIQUIBASE_PASSWORD="postgres", HTTP_ADDRESS="127.0.0.1",
                   HTTP_PORT=str(api_port), FRONTEND_PORT=str(frontend_port), ZIGMA_STARTUP_TIMEOUT="60")
        if CONFIG.jdbc_classpath:
            env["LIQUIBASE_CLASSPATH"] = CONFIG.jdbc_classpath

        def http(method, target, body=None, status=200, port=api_port):
            connection = HTTPConnection("127.0.0.1", port, timeout=3)
            try:
                connection.request(method, target, None if body is None else json.dumps(body), {"Content-Type": "application/json"})
                response = connection.getresponse()
                data = response.read()
                self.assertEqual(response.status, status, data.decode(errors="replace"))
                return data
            finally:
                connection.close()

        def start():
            log_path = self.workspace / f"server-{time.monotonic_ns()}.log"
            log = log_path.open("w")
            self.addCleanup(log.close)
            process = subprocess.Popen([str(launcher), str(backend), str(self.prefix / "frontend")],
                                       cwd=self.application, env=env, stdout=log, stderr=log, start_new_session=True)
            self.addCleanup(stop, process)
            deadline = time.monotonic() + 90
            while True:
                if process.poll() is not None:
                    self.fail(log_path.read_text())
                try:
                    http("GET", "/api/productos")
                    http("GET", "/", port=frontend_port)
                    return process
                except (OSError, HTTPException):
                    self.assertLess(time.monotonic(), deadline, log_path.read_text())
                    time.sleep(0.1)

        process = start()
        for entity in ENTITIES:
            self.assertEqual(json.loads(http("GET", "/api/" + entity)), [])
        http("GET", "/api/docentes", status=404)
        self.assertIn(b"<html", http("GET", "/", port=frontend_port))
        self.assertEqual(http("GET", "/frontend.wasm", port=frontend_port)[:8], b"\x00asm\x01\x00\x00\x00")
        http("POST", "/api/productos", {"id": 1, "nombre": "Yerba", "descripcion": "Paquete"}, 201)
        http("POST", "/api/productos", {"id": 2, "nombre": "Arroz", "descripcion": "Bolsa"}, 201)
        price = {"id": 1, "id_producto": 1, "vigencia_desde": "2026-11-12T12:30:00.120Z", "precio": 199}
        http("POST", "/api/productos_precios", price, 201)
        http("POST", "/api/productos_precios", {**price, "id": 2, "id_producto": 2}, 201)
        http("POST", "/api/productos_precios", {**price, "id": 3}, 409)
        http("POST", "/api/productos_precios", {**price, "id": 4, "precio": 0}, 422)
        promotion = {"id": 1, "id_producto": 1, "vigencia_desde": price["vigencia_desde"], "cantidad_llevar": 3, "descuento_porcentaje": 10, "activo": True}
        http("POST", "/api/descuentos_cantidad", promotion, 201)
        http("POST", "/api/descuentos_cantidad", {**promotion, "id": 2, "id_producto": 2}, 201)
        cart = {"id": 1, "fecha_inicio": price["vigencia_desde"], "estado": "abierto"}
        http("POST", "/api/carritos", cart, 201)
        http("POST", "/api/carritos", {**cart, "id": 2}, 201)
        detail = {"id_carrito": 1, "id_producto": 1, "cantidad": 3, "id_precio": 1, "id_descuento": 1}
        http("POST", "/api/productos_carritos", detail, 201)
        http("POST", "/api/productos_carritos", {**detail, "id_carrito": 2, "id_precio": 2}, 409)
        http("POST", "/api/productos_carritos", {**detail, "id_carrito": 2, "id_descuento": 2}, 409)
        self.assertEqual(len(json.loads(http("GET", "/api/productos_carritos"))), 1)
        ticket = {"id": 1, "id_carrito": 1, "fecha_emision": price["vigencia_desde"], "total": 537}
        http("POST", "/api/tickets", ticket, 201)
        http("POST", "/api/tickets", {**ticket, "id": 2}, 409)
        http("POST", "/api/tickets_productos", {"id_ticket": 1, "id_producto": 1, "cantidad": 3, "precio_unitario": 199, "importe_descuento": 60}, 201)
        http("POST", "/api/clientes", {"id": 1, "nombre": "Ana"}, 201)
        http("PUT", "/api/clientes?id=1", {"nombre": "Ana María"})
        http("DELETE", "/api/clientes?id=1")
        self.assertEqual(json.loads(http("GET", "/api/clientes")), [])
        self.assertEqual(json.loads(http("GET", "/api/productos_precios?id=1"))[0], price)
        stop(process)
        start()
        self.assertEqual(json.loads(http("GET", "/api/productos_precios?id=1"))[0], price)
        stored_ticket = json.loads(http("GET", "/api/tickets?id=1"))[0]
        self.assertEqual(stored_ticket, {**ticket, "id_cliente": None})
        count = subprocess.check_output(["docker", "exec", container, "psql", "-U", "postgres", "-d", "supermercado", "-Atc", "SELECT count(*) FROM databasechangelog"], text=True)
        self.assertEqual(int(count.strip()), 1, "El segundo arranque no debe repetir el baseline")


if __name__ == "__main__":
    unittest.main(argv=[__file__, *TEST_ARGS])
