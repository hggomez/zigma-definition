#!/usr/bin/env python3
"""Arranca el backend real de AIDA y sirve su frontend hasta recibir Ctrl+C."""

import functools
import http.client
import http.server
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import threading
import time


def port_from_env(name, default):
    port = int(os.environ.get(name, str(default)))
    if not 1 <= port <= 65535:
        raise ValueError(f"{name} debe estar entre 1 y 65535")
    return port


def backend_ready(host, port):
    connection = http.client.HTTPConnection(host, port, timeout=0.3)
    try:
        # OPTIONS verifica el transporte ya iniciado sin consultar filas de la base.
        connection.request("OPTIONS", "/api/")
        response = connection.getresponse()
        response.read()
        return response.status == 204
    except (OSError, http.client.HTTPException):
        return False
    finally:
        connection.close()


def stop_backend(process):
    # Liquibase también pertenece a este grupo durante el arranque.
    if os.name == "posix":
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    elif process.poll() is None:
        process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    if os.name == "posix":
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline:
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.05)
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def run(backend, frontend):
    backend_port = port_from_env("HTTP_PORT", 8080)
    frontend_port = port_from_env("FRONTEND_PORT", 8000)
    address = os.environ.get("HTTP_ADDRESS", "127.0.0.1")
    host = {"0.0.0.0": "127.0.0.1", "::": "::1"}.get(address, address).strip("[]")
    url_host = f"[{host}]" if ":" in host else host
    api_url = f"http://{url_host}:{backend_port}/api"
    startup_timeout = float(os.environ.get("AIDA_STARTUP_TIMEOUT", "120"))
    if startup_timeout <= 0:
        raise ValueError("AIDA_STARTUP_TIMEOUT debe ser positivo")
    if not (frontend / "index.html").is_file():
        raise ValueError("No se encontró el frontend compilado (index.html)")
    # Evita confundir una API ya abierta con el proceso que vamos a iniciar.
    try:
        connection = socket.create_connection((host, backend_port), timeout=0.3)
    except OSError:
        pass
    else:
        connection.close()
        raise ValueError(f"El puerto del backend ({backend_port}) ya está ocupado")
    if backend_port == frontend_port:
        raise ValueError("HTTP_PORT y FRONTEND_PORT deben ser distintos")

    config = f"globalThis.ZIGMA_API_BASE = {json.dumps(api_url)};\n".encode()

    class FrontendHandler(http.server.SimpleHTTPRequestHandler):
        extensions_map = {**http.server.SimpleHTTPRequestHandler.extensions_map,
                          ".wasm": "application/wasm"}

        def do_GET(self):
            if self.path.split("?", 1)[0] == "/api-config.js":
                self.send_response(200)
                self.send_header("Content-Type", "application/javascript; charset=utf-8")
                self.send_header("Content-Length", str(len(config)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(config)
            else:
                super().do_GET()

    # Reserva el puerto del frontend antes de iniciar las migraciones.
    try:
        server = http.server.ThreadingHTTPServer(
            ("127.0.0.1", frontend_port),
            functools.partial(FrontendHandler, directory=str(frontend)),
        )
    except OSError as error:
        raise ValueError(f"No se pudo abrir el puerto del frontend ({frontend_port}): {error.strerror}") from error

    process = None
    serving = None
    try:
        process = subprocess.Popen([str(backend)], start_new_session=True)
        print("Iniciando AIDA con PostgreSQL; esperando migraciones y API...", flush=True)
        deadline = time.monotonic() + startup_timeout
        while not backend_ready(host, backend_port):
            if process.poll() is not None:
                return process.returncode or 1
            if time.monotonic() >= deadline:
                raise TimeoutError("La API no estuvo disponible dentro de AIDA_STARTUP_TIMEOUT")
            time.sleep(0.1)

        serving = threading.Thread(target=server.serve_forever, daemon=True)
        serving.start()
        print(f"Frontend: http://127.0.0.1:{frontend_port}/\nAPI PostgreSQL: {api_url}\nCtrl+C detiene ambos.", flush=True)
        while process.poll() is None and serving.is_alive():
            time.sleep(0.1)
        return process.returncode or 1
    finally:
        if serving is not None:
            server.shutdown()
            serving.join()
        server.server_close()
        if process is not None:
            stop_backend(process)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Uso: run_aida.py <aida-rest-server> <frontend-directory>")

    def interrupted(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupted)
    try:
        return run(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
    except KeyboardInterrupt:
        return 0
    except (OSError, ValueError) as error:
        print(f"No se pudo iniciar AIDA: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
