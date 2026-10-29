"""Mismos casos de edad contra ambos backends descartables; nunca usa DATABASE_URL."""

from datetime import datetime, timedelta, timezone
import http.client
import json
import sys
from urllib.parse import urlsplit


def check_docente_age(request):
    today = datetime.now(timezone(timedelta(hours=-3))).date()
    old = {"año": today.year - 40, "mes": 1, "día": 1}
    # Lejos del umbral para que un cambio de día/año durante la integración no
    # altere el resultado. El cumpleaños exacto se prueba con contexto fijo en Zig.
    young = {"año": today.year - 20, "mes": 1, "día": 1}
    future = {"año": today.year + 1, "mes": 1, "día": 1}
    base = {"docente": "age-check", "nombres": "Prueba", "cargo": "teorico", "experiencia": 5}
    path = "/api/docentes?docente=age-check"

    def reject(body, code, message, method="POST", target="/api/docentes"):
        assert request(method, target, body, expected=422) == {"error": {"code": code, "message": message}}

    missing = ("teorico_requires_birth_date", "A docente with cargo 'teorico' requires fecha_nacimiento")
    underage = ("teorico_requires_thirty_years", "A docente with cargo 'teorico' must be at least 30 years old")
    future_error = ("birth_date_in_future", "A docente's birth date cannot be in the future")
    reject(base, *missing)
    reject({**base, "fecha_nacimiento": None}, *missing)
    reject({**base, "fecha_nacimiento": young}, *underage)
    reject({**base, "fecha_nacimiento": future}, *future_error)
    assert request("GET", path) == []

    row = request("POST", "/api/docentes", {**base, "cargo": "practico", "fecha_nacimiento": young}, expected=201)
    reject({"cargo": "teorico"}, *underage, method="PUT", target=path)
    assert request("GET", path) == [row]
    accepted = {**row, "cargo": "teorico", "fecha_nacimiento": old}
    assert request("PUT", path, {"cargo": "teorico", "fecha_nacimiento": old}) == [accepted]
    assert request("PUT", path, {"nombres": "Otro nombre"}) == [{**accepted, "nombres": "Otro nombre"}]
    accepted["nombres"] = "Otro nombre"
    for birth, violation in ((None, missing), (young, underage), (future, future_error)):
        reject({"fecha_nacimiento": birth}, *violation, method="PUT", target=path)
        assert request("GET", path) == [accepted]
    assert request("DELETE", path) == [accepted]

    # Una fila válida y otra menor: ninguna debe quedar actualizada por el PUT grupal.
    for number, birth in ((1, old), (2, young)):
        request("POST", "/api/docentes", {
            **base, "docente": f"age-group-{number}", "cargo": "practico",
            "telefono": "age-check-group", "fecha_nacimiento": birth,
        }, expected=201)
    group_path = "/api/docentes?telefono=age-check-group"
    before = request("GET", group_path)
    assert len(before) == 2
    reject({"cargo": "teorico"}, *underage, method="PUT", target=group_path)
    assert sorted(request("GET", group_path), key=lambda row: row["docente"]) == sorted(before, key=lambda row: row["docente"])
    assert len(request("DELETE", group_path)) == 2


def main():
    target = urlsplit(sys.argv[1])
    assert target.scheme == "http" and target.hostname in ("127.0.0.1", "localhost")

    def request(method, path, body=None, expected=200):
        connection = http.client.HTTPConnection(target.hostname, target.port, timeout=3)
        headers = {}
        if body is not None:
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        try:
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            payload = response.read()
            assert response.status == expected, (method, path, response.status, payload)
            return json.loads(payload)
        finally:
            connection.close()

    check_docente_age(request)
    print("OK: edad de docente, fechas ausentes/futuras y rechazo sin cambios parciales")


if __name__ == "__main__":
    main()
