#!/usr/bin/env python3
"""Comprueba contexto por solicitud y errores del proveedor en un puerto propio."""

import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]

    def request():
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        try:
            connection.request("GET", "/api/things?sequence=999")
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    with tempfile.TemporaryFile() as log:
        process = subprocess.Popen([binary], env={**os.environ, "HTTP_PORT": str(port)}, stdout=log, stderr=log)
        try:
            for _ in range(100):
                if process.poll() is not None:
                    raise AssertionError("El servidor de contexto terminó antes de iniciar")
                try:
                    first = request()
                    break
                except ConnectionRefusedError:
                    time.sleep(0.05)
            else:
                raise AssertionError("El servidor de contexto no inició")
            assert first == (200, {"sequence": 1, "api_calls": 1}), first
            assert request() == (200, {"sequence": 2, "api_calls": 2})
            assert request() == (500, {"error": {"code": "internal_error", "message": "Internal server error"}})
            assert request() == (200, {"sequence": 4, "api_calls": 3})
            assert process.wait(timeout=5) == 0
            print("OK: contexto por solicitud, renovación, error sanitizado y recuperación")
        except BaseException:
            log.seek(0)
            sys.stderr.write(log.read().decode("utf-8", errors="replace"))
            raise
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3)


if __name__ == "__main__":
    main()
