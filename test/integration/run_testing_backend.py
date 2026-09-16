#!/usr/bin/env python3
"""Comprueba el backend de pruebas de AIDA con un proceso y puerto propios."""

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
    if len(sys.argv) != 2:
        raise SystemExit("Uso: run_testing_backend.py <testing-backend-binary>")
    binary = str(Path(sys.argv[1]).resolve())
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        port = listener.getsockname()[1]
    env = {**os.environ, "HTTP_ADDRESS": "127.0.0.1", "HTTP_PORT": str(port)}

    def request(method, path, body=None, expected=200):
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
        headers = {"Origin": "http://localhost:8000"}
        if body is not None:
            body = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            payload = response.read()
            assert response.status == expected, (method, path, response.status, payload)
            assert response.getheader("Access-Control-Allow-Origin") == "*"
            if method == "OPTIONS":
                assert "PUT" in response.getheader("Access-Control-Allow-Methods", "")
                assert response.getheader("Access-Control-Allow-Headers") == "Content-Type"
            return json.loads(payload) if payload else None
        finally:
            connection.close()

    with tempfile.TemporaryFile() as log:
        def start():
            process = subprocess.Popen([binary], env=env, stdout=log, stderr=log)
            try:
                for _ in range(100):
                    if process.poll() is not None:
                        raise AssertionError("El backend terminó antes de aceptar solicitudes")
                    try:
                        rows = request("GET", "/api/materias")
                        assert any(row["materia"] == "AlgoI" for row in rows)
                        return process
                    except ConnectionRefusedError:
                        time.sleep(0.05)
                raise AssertionError("El backend no inició a tiempo")
            except BaseException:
                stop(process)
                raise

        process = None
        try:
            process = start()
            request("OPTIONS", "/api/materias", expected=204)
            docentes = request("GET", "/api/docentes?docente=1")
            assert len(docentes) == 1 and docentes[0]["telefono"] is None
            assert request("GET", "/api/clases?orden=1&materia=AlgoI&periodo=1C2024")[0]["fecha"] == {
                "año": 2024, "mes": 3, "día": 15,
            }
            row = {"materia": "testing-backend-check", "denominacion": "Prueba HTTP"}
            assert request("POST", "/api/materias", row, expected=201) == row
            path = "/api/materias?materia=testing-backend-check"
            assert request("GET", path) == [row]
            changed = {**row, "denominacion": "Prueba actualizada"}
            assert request("PUT", path, {"denominacion": changed["denominacion"]}) == [changed]
            assert request("DELETE", path) == [changed]
            assert request("GET", path) == []
            violation = request("POST", "/api/docentes", {
                "docente": "invalid-check", "nombres": "Prueba",
                "cargo": "teorico", "experiencia": 4,
            }, expected=422)
            assert violation["error"]["code"] == "teorico_requires_five_years_experience"
            assert request("GET", "/api/docentes?docente=invalid-check") == []
            request("GET", "/api/desconocida", expected=404)
            request("POST", "/api/materias", row, expected=201)
            stop(process)
            process = start()
            assert request("GET", path) == []
            print("OK: seeds, CORS, filtros, CRUD, validación de negocio y reinicio sin persistencia")
        except BaseException:
            log.seek(0)
            sys.stderr.write(log.read().decode("utf-8", errors="replace"))
            raise
        finally:
            if process is not None:
                stop(process)


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


if __name__ == "__main__":
    main()
