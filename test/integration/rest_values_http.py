#!/usr/bin/env python3
"""CORS y valores REST contra el PostgreSQL descartable de run_rest_postgres.sh."""
import http.client
import json
import sys
from urllib.parse import urlencode, urlsplit


def main():
    base = urlsplit(sys.argv[1])

    def request(method, path, value=None, expected=200):
        connection = http.client.HTTPConnection(base.hostname, base.port, timeout=3)
        headers = {"Origin": "http://localhost:8000"}
        body = None
        if value is not None:
            body = json.dumps(value, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        try:
            connection.request(method, base.path + path, body=body, headers=headers)
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

    request("OPTIONS", "/materias", expected=204)
    row = {"materia": "wire-subject", "denominacion": 'Prueba "HTTP"\\ruta\nñ'}
    assert request("POST", "/materias", row, expected=201) == row
    assert request("GET", "/materias?materia=wire-subject") == [row]
    original = request("POST", "/docentes", {"docente": "wire-docente", "nombres": "Original"}, expected=201)
    path = "/docentes?docente=wire-docente"
    changed = {**original, "nombres": 'Nombre "visible"\\aula\nñ'}
    assert request("PUT", path, {"nombres": changed["nombres"]}) == [changed]
    assert request("GET", path)[0]["esImportador"] is None
    for flag in (True, False, None):
        changed["esImportador"] = flag
        assert request("PUT", path, {"esImportador": flag}) == [changed]
        assert request("GET", path) == [changed]

    request("POST", "/periodos", {"periodo": "wire-period"}, expected=201)
    request("POST", "/cursos", {"periodo": "wire-period", "materia": "wire-subject", "docente": "wire-docente"}, expected=201)
    original_class = request("POST", "/clases", {
        "periodo": "wire-period", "materia": "wire-subject", "orden": 1,
        "fecha": {"año": 2024, "mes": 3, "día": 15},
    }, expected=201)
    class_path = "/clases?orden=1&materia=wire-subject&periodo=wire-period"
    assert request("PUT", class_path, {"fecha": None}) == [{**original_class, "fecha": None}]
    assert request("PUT", class_path, {"fecha": original_class["fecha"]}) == [original_class]
    invalid_request = {"error": {"code": "invalid_request", "message": "Request fields or values are invalid"}}
    for date in ("2025-02-30", json.dumps({"año": 2025, "mes": 2, "día": 30})):
        invalid_path = "/clases?" + urlencode({"fecha": date})
        for method in ("GET", "PUT", "DELETE"):
            value = {"tema": "No debe escribirse"} if method == "PUT" else None
            assert request(method, invalid_path, value, expected=400) == invalid_request
        assert request("GET", class_path) == [original_class]

    request("GET", "/desconocida", expected=404)
    assert request("DELETE", class_path) == [original_class]
    request("DELETE", "/cursos?periodo=wire-period&materia=wire-subject")
    request("DELETE", "/periodos?periodo=wire-period")
    assert request("DELETE", "/materias?materia=wire-subject") == [row]
    assert request("GET", "/materias?materia=wire-subject") == []
    assert request("DELETE", path) == [changed]
    print("OK: CORS, escaping, null/false/true y filtros de fecha sin escrituras parciales")


if __name__ == "__main__":
    main()
