#!/usr/bin/env python3
"""Pruebas del arranque conjunto, con procesos y puertos propios; sin PostgreSQL."""

import http.client
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest

# El build entrega el lanzador nativo a probar; solo los backends simulados usan Python.
LAUNCHER = Path(sys.argv.pop(1)).resolve()


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def get(port, path):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=0.3)
    try:
        connection.request("GET", path)
        response = connection.getresponse()
        return response.status, response.read(), response.getheader("Content-Type", "")
    finally:
        connection.close()


class LauncherTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.log = tempfile.TemporaryFile()
        self.addCleanup(self.log.close)
        self.frontend = self.directory / "frontend"
        self.frontend.mkdir()
        (self.frontend / "index.html").write_text("<h1>AIDA</h1>")
        (self.frontend / "frontend.wasm").write_bytes(b"\x00asm\x01\x00\x00\x00")
        self.backend_port = free_port()
        self.frontend_port = free_port()
        self.marker = self.directory / "backend.pid"
        self.backend = self.directory / "backend"
        self.backend.write_text(f"#!{sys.executable}\n" + '''
import http.server, os, pathlib, signal, subprocess, sys, time
if os.environ.get("IGNORE_TERM") == "1":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
pathlib.Path(os.environ["PID_FILE"]).write_text(str(os.getpid()))
if os.environ.get("FAIL_BACKEND") == "1":
    raise SystemExit(17)
if os.environ.get("WITH_CHILD") == "1":
    subprocess.Popen([sys.executable, "-c", ''' + repr('''
import os, pathlib, signal, time
def finish(*args):
    pathlib.Path(os.environ["CHILD_STOPPED"]).write_text("stopped")
    raise SystemExit(0)
signal.signal(signal.SIGTERM, finish)
pathlib.Path(os.environ["CHILD_READY"]).write_text("ready")
time.sleep(60)
''') + '''])
time.sleep(float(os.environ.get("BACKEND_DELAY", "0")))
class Handler(http.server.BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        time.sleep(float(os.environ.get("OPTIONS_DELAY", "0")))
        self.send_response(int(os.environ.get("OPTIONS_STATUS", "204")))
        self.end_headers()
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"[]")
    def log_message(self, *args):
        pass
http.server.HTTPServer(("127.0.0.1", int(os.environ["HTTP_PORT"])), Handler).serve_forever()
''')
        self.backend.chmod(0o755)

    def start(self, **extra):
        env = {**os.environ, "HTTP_ADDRESS": "127.0.0.1", "HTTP_PORT": str(self.backend_port),
               "FRONTEND_PORT": str(self.frontend_port), "PID_FILE": str(self.marker), **extra}
        self.process = subprocess.Popen(
            [str(LAUNCHER), str(self.backend), str(self.frontend)],
            env=env, stdout=self.log, stderr=self.log,
        )
        self.addCleanup(self.stop)

    def stop(self):
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGINT)
            self.process.wait(timeout=8)

    def wait_frontend(self):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                self.log.seek(0)
                self.fail(self.log.read().decode())
            try:
                if get(self.frontend_port, "/")[0] == 200:
                    return
            except (OSError, http.client.HTTPException):
                pass
            time.sleep(0.03)
        self.fail("El frontend no inició a tiempo")

    def assert_backend_stopped(self):
        pid = int(self.marker.read_text())
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        with self.assertRaises(OSError):
            get(self.backend_port, "/api/materias")

    def test_serves_assets_and_config_and_ctrl_c_stops_backend(self):
        self.start()
        self.wait_frontend()
        self.assertEqual(get(self.frontend_port, "/")[1], b"<h1>AIDA</h1>")
        status, config, _ = get(self.frontend_port, "/api-config.js")
        self.assertEqual(status, 200)
        self.assertIn(f"http://127.0.0.1:{self.backend_port}/api".encode(), config)
        self.assertEqual(get(self.frontend_port, "/frontend.wasm")[2], "application/wasm")
        self.stop()
        self.assertEqual(self.process.returncode, 0)
        self.assert_backend_stopped()

    def test_backend_startup_failure_does_not_leave_frontend_running(self):
        self.start(FAIL_BACKEND="1")
        self.assertEqual(self.process.wait(timeout=8), 17)
        self.assert_backend_stopped()
        with self.assertRaises(OSError):
            get(self.frontend_port, "/")

    def test_backend_exit_stops_frontend(self):
        self.start()
        self.wait_frontend()
        os.kill(int(self.marker.read_text()), signal.SIGTERM)
        self.assertNotEqual(self.process.wait(timeout=8), 0)
        with self.assertRaises(OSError):
            get(self.frontend_port, "/")

    def test_launcher_does_not_require_python_on_path(self):
        # El shebang absoluto del backend simulado evita depender del PATH vacío.
        self.start(PATH="")
        self.wait_frontend()
        self.assertEqual(get(self.frontend_port, "/")[0], 200)

    def test_shutdown_forces_backend_that_ignores_term(self):
        self.start(IGNORE_TERM="1")
        self.wait_frontend()
        self.stop()
        self.assertEqual(self.process.returncode, 0)
        self.assert_backend_stopped()

    def test_frontend_port_conflict_fails_before_starting_backend(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", self.frontend_port))
            listener.listen()
            self.start()
            self.assertNotEqual(self.process.wait(timeout=8), 0)
            self.assertFalse(self.marker.exists())
            self.log.seek(0)
            self.assertIn(b"puerto del frontend", self.log.read())

    def test_backend_port_conflict_does_not_start_another_backend(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", self.backend_port))
            listener.listen()
            self.start()
            self.assertNotEqual(self.process.wait(timeout=8), 0)
            self.assertFalse(self.marker.exists())
            self.log.seek(0)
            self.assertIn(b"puerto del backend", self.log.read())

    def test_startup_timeout_cleans_up_backend(self):
        self.start(BACKEND_DELAY="5", AIDA_STARTUP_TIMEOUT="1")
        self.assertNotEqual(self.process.wait(timeout=8), 0)
        self.assert_backend_stopped()

    def test_unresponsive_api_does_not_block_timeout(self):
        self.start(OPTIONS_DELAY="60", AIDA_STARTUP_TIMEOUT="1")
        self.assertNotEqual(self.process.wait(timeout=8), 0)
        self.assert_backend_stopped()

    def test_non_ready_http_status_does_not_start_frontend(self):
        self.start(OPTIONS_STATUS="503", AIDA_STARTUP_TIMEOUT="1")
        self.assertNotEqual(self.process.wait(timeout=8), 0)
        self.assert_backend_stopped()
        with self.assertRaises(OSError):
            get(self.frontend_port, "/")

    def test_sigterm_with_idle_http_client_stops_everything(self):
        self.start()
        self.wait_frontend()
        with socket.create_connection(("127.0.0.1", self.frontend_port)) as client:
            client.sendall(b"GET / HTTP/1.1\r\n")
            time.sleep(0.1)
            self.process.send_signal(signal.SIGTERM)
            self.assertEqual(self.process.wait(timeout=8), 0)
        self.assert_backend_stopped()

    def test_idle_connection_does_not_block_other_assets(self):
        self.start()
        self.wait_frontend()
        with socket.create_connection(("127.0.0.1", self.frontend_port)) as client:
            client.sendall(b"GET / HTTP/1.1\r\n")
            time.sleep(0.1)
            self.assertEqual(get(self.frontend_port, "/frontend.wasm")[0], 200)

    def test_missing_frontend_does_not_start_backend(self):
        (self.frontend / "index.html").unlink()
        self.start()
        self.assertNotEqual(self.process.wait(timeout=8), 0)
        self.assertFalse(self.marker.exists())

    def test_equal_ports_do_not_start_backend(self):
        self.start(FRONTEND_PORT=str(self.backend_port))
        self.assertNotEqual(self.process.wait(timeout=8), 0)
        self.assertFalse(self.marker.exists())

    def test_invalid_configuration_does_not_start_backend(self):
        for name, value in (("HTTP_PORT", "0"), ("FRONTEND_PORT", "65536"),
                            ("AIDA_STARTUP_TIMEOUT", "nan"), ("AIDA_STARTUP_TIMEOUT", "-1")):
            with self.subTest(name=name, value=value):
                self.start(**{name: value})
                self.assertNotEqual(self.process.wait(timeout=8), 0)
                self.assertFalse(self.marker.exists())

    def test_static_http_paths_headers_and_missing_assets(self):
        (self.frontend / "hello world.js").write_text("const greeting = '¡Hola!';")
        (self.directory / "private.txt").write_text("No pertenece al frontend")
        self.start()
        self.wait_frontend()
        status, body, content_type = get(self.frontend_port, "/hello%20world.js?v=1")
        self.assertEqual(status, 200)
        self.assertEqual(body.decode(), "const greeting = '¡Hola!';")
        self.assertIn("javascript", content_type)
        self.assertEqual(get(self.frontend_port, "/missing.js")[0], 404)
        for path in ("/../private.txt", "/%2e%2e/private.txt", "/%2fetc/passwd"):
            self.assertIn(get(self.frontend_port, path)[0], (400, 404))
        connection = http.client.HTTPConnection("127.0.0.1", self.frontend_port, timeout=1)
        try:
            connection.request("HEAD", "/api-config.js?v=1")
            response = connection.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(response.getheader("Cache-Control"), "no-store")
            self.assertGreater(int(response.getheader("Content-Length")), 0)
            self.assertEqual(response.read(), b"")
        finally:
            connection.close()

    def test_ctrl_c_during_startup_stops_backend_and_its_child(self):
        ready = self.directory / "child.ready"
        stopped = self.directory / "child.stopped"
        self.start(BACKEND_DELAY="60", WITH_CHILD="1", CHILD_READY=str(ready), CHILD_STOPPED=str(stopped))
        deadline = time.monotonic() + 5
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.03)
        self.assertTrue(ready.exists())
        self.stop()
        self.assertEqual(self.process.returncode, 0)
        self.assert_backend_stopped()
        self.assertTrue(stopped.exists(), "El subproceso también debe recibir la señal de cierre")


if __name__ == "__main__":
    unittest.main()
