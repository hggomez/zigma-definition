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
from urllib.parse import urlencode

# El auxiliar compartido no debe dejar bytecode dentro del árbol de trabajo.
sys.dont_write_bytecode = True
from docente_age_http import check_docente_age


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
            check_docente_age(request)
            request("OPTIONS", "/api/materias", expected=204)
            docentes = request("GET", "/api/docentes?docente=1")
            assert len(docentes) == 1 and docentes[0]["telefono"] is None
            original_docente = docentes[0]
            docente_path = "/api/docentes?docente=1"
            changed_docente = {**original_docente, "nombres": 'Nombre "visible"\\aula\nñ'}
            assert request("PUT", docente_path, {"nombres": changed_docente["nombres"]}) == [changed_docente]
            assert request("GET", docente_path)[0]["esImportador"] is None
            for flag in (True, False, None):
                changed_docente["esImportador"] = flag
                assert request("PUT", docente_path, {"esImportador": flag}) == [changed_docente]
            assert request("GET", "/api/clases?orden=1&materia=AlgoI&periodo=1C2024")[0]["fecha"] == {
                "año": 2024, "mes": 3, "día": 15,
            }
            clase_path = "/api/clases?orden=1&materia=AlgoI&periodo=1C2024"
            original_clase = request("GET", clase_path)[0]
            assert request("PUT", clase_path, {"fecha": None}) == [{**original_clase, "fecha": None}]
            assert request("PUT", clase_path, {"fecha": original_clase["fecha"]}) == [original_clase]
            invalid_request = {"error": {"code": "invalid_request", "message": "Request fields or values are invalid"}}
            invalid_date = {"año": 2025, "mes": 2, "día": 30}
            invalid_clase = {**original_clase, "orden": 99, "fecha": invalid_date}
            assert request("POST", "/api/clases", invalid_clase, expected=400) == invalid_request
            assert request("GET", "/api/clases?orden=99&materia=AlgoI&periodo=1C2024") == []
            for invalid in (invalid_date, {"año": 0, "mes": 1, "día": 1}, {"año": 10000, "mes": 1, "día": 1}, "2024-02-29"):
                assert request("PUT", clase_path, {"fecha": invalid}, expected=400) == invalid_request
                assert request("GET", clase_path) == [original_clase]
            for invalid_filter in ("2025-02-30", json.dumps(invalid_date)):
                invalid_path = "/api/clases?" + urlencode({"fecha": invalid_filter})
                for method in ("GET", "PUT", "DELETE"):
                    body = {"tema": "No debe escribirse"} if method == "PUT" else None
                    assert request(method, invalid_path, body, expected=400) == invalid_request
                assert request("GET", clase_path) == [original_clase]
            for valid_date, iso in (({"año": 1, "mes": 1, "día": 1}, "0001-01-01"),
                                    ({"año": 2000, "mes": 2, "día": 29}, "2000-02-29"),
                                    ({"año": 9999, "mes": 12, "día": 31}, "9999-12-31")):
                expected_clase = {**original_clase, "fecha": valid_date}
                assert request("PUT", clase_path, {"fecha": valid_date}) == [expected_clase]
                for date_filter in (iso, json.dumps(valid_date)):
                    matching = request("GET", "/api/clases?" + urlencode({"fecha": date_filter}))
                    assert expected_clase in matching
            assert request("PUT", clase_path, {"fecha": original_clase["fecha"]}) == [original_clase]
            row = {"materia": "testing-backend-check", "denominacion": 'Prueba "HTTP"\\ruta\nñ'}
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
            print("OK: seeds, CORS, filtros, CRUD, JSON escapado, null/false/true, fechas, reglas y reinicio")
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
