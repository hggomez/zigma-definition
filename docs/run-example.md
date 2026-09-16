# Ejecutar el frontend con el backend de pruebas

El ejemplo `examples/aida/` consume el framework y compila un frontend WASM y un
backend de pruebas en memoria. Ambos usan el contrato de AIDA. El backend reutiliza
la API REST y el transporte `std_http` del servidor PostgreSQL; no requiere base de
datos, libpq ni Liquibase. Al terminar el proceso se pierden las modificaciones.

La arquitectura del frontend está en [frontend.md](frontend.md); la composición del
build, en [build.md](build.md).

## Inicio rápido

Desde la raíz del repositorio, en una terminal:

```sh
cd examples/aida
zig build testing-backend
```

El mensaje inicial indica `Testing backend (in memory) listening on http://127.0.0.1:8080/api`.
Este comando reemplaza `zig build backend` y el alias `zig build dummy`.

En otra terminal, también desde la raíz:

```sh
cd examples/aida
zig build frontend
python3 -m http.server 8000 --directory zig-out/frontend
```

Abrí <http://localhost:8000/>. La página consulta el backend en el puerto 8080 y permite
listar, crear, modificar y eliminar filas. CORS se resuelve en el transporte compartido.
Los seeds se cargan al iniciar el backend; reiniciarlo restaura esos datos.

## Compilación y configuración

Desde `examples/aida/`, `zig build` instala ambos artefactos:

- `zig-out/bin/testing-backend`: ejecutable del backend de pruebas.
- `zig-out/frontend/`: `frontend.wasm`, HTML, JavaScript, título y widgets del ejemplo.

También podés ejecutar el binario directamente:

```sh
./zig-out/bin/testing-backend
```

`HTTP_ADDRESS` y `HTTP_PORT` permiten cambiar la dirección y el puerto. Los valores por
default son `127.0.0.1` y `8080`. El frontend configura su URL en `src/frontend/main.js`;
si cambiás el puerto del backend, ajustá también esa URL.

Este servidor anuncia su dirección al iniciar; la lectura de solicitudes, CORS,
límites y respuestas HTTP quedan a cargo de `src/rest/std_http.zig`.

## Probar la API

Las rutas son las mismas que en el servidor PostgreSQL:

- `GET /api/{entity}` devuelve un array y admite filtros de igualdad en la query.
- `POST /api/{entity}` recibe JSON y devuelve `201` con la fila creada.
- `PUT /api/{entity}?campo=valor` modifica los campos enviados; las PK no pueden estar
  en el cuerpo. Devuelve `200` y un array con las filas modificadas.
- `DELETE /api/{entity}?campo=valor` devuelve `200` y un array con las filas eliminadas.
- PUT y DELETE requieren al menos un filtro. Los errores tienen la forma
  `{"error":{"code":"...","message":"..."}}`.

```sh
curl http://localhost:8080/api/materias

curl -i http://localhost:8080/api/materias \
  -H 'Content-Type: application/json' \
  -d '{"materia":"REDES","denominacion":"Redes de Computadoras"}'

curl -i -X PUT 'http://localhost:8080/api/materias?materia=REDES' \
  -H 'Content-Type: application/json' \
  -d '{"denominacion":"Redes y Comunicaciones"}'

curl -i -X DELETE 'http://localhost:8080/api/materias?materia=REDES'
```

Desde `examples/aida/`, esta comprobación requiere Python 3 y usa un proceso y puerto
propios, sin modificar los datos de otro backend que esté ejecutándose:

```sh
zig build test-backend
```

Verifica seeds, CORS, filtros, CRUD, reglas de negocio y que el reinicio descarte los
cambios. El repositorio en memoria no reproduce todas las restricciones y garantías de
PostgreSQL; las integraciones con la base se ejecutan por separado.

## Archivos principales

| Archivo | Responsabilidad |
| --- | --- |
| `examples/aida/src/aida.zig` | Contrato de AIDA. |
| `examples/aida/src/system.zig` | Contrato y seeds del ejemplo. |
| `examples/aida/src/rest.zig` | Codecs y API de AIDA, compartidos con el servidor PostgreSQL. |
| `examples/aida/build.zig` | Compone la app y publica la comprobación `test-backend`. |
| `src/testing_backend/main.zig` | Inicializa API, seeds y repositorio; llama a `std_http.serve`. |
| `src/testing_backend/memory_repository.zig` | CRUD en memoria. |
| `src/rest/std_http.zig` | Transporte HTTP compartido y CORS. |
| `src/frontend/` | Cliente WASM y recursos de la página. |

Para ejecutar AIDA con PostgreSQL y migraciones, consultá el [README](../README.md).
