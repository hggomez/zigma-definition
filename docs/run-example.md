# Ejecutar AIDA y su frontend

AIDA usa el frontend WASM del framework y el servidor compartido `src/server.zig`,
que aplica el historial de Liquibase y persiste mediante PostgreSQL. Su composición
está en `examples/aida/build/application.zig`. La arquitectura del frontend está en [frontend.md](frontend.md)
y la del build, en [build.md](build.md).

## Inicio rápido

Prepará PostgreSQL, libpq, Liquibase y las variables de conexión siguiendo el
[README](../README.md#arrancar-aida-con-postgresql). Desde `examples/aida/`:

```sh
zig build run -Dlibpq-prefix=/opt/homebrew/opt/libpq
```

El comando compila el frontend, inicia el backend y espera a que termine de aplicar
las migraciones. Abrí `http://127.0.0.1:8000/`. Ctrl+C cierra ambos procesos.
El historial vive en `examples/aida/db/`; los procesos arrancan desde `examples/aida/`
para resolver `db/changelog-root.yaml`. Los datos de demostración se incorporan por
el changeset SQL aceptado y las modificaciones persisten al reiniciar.

`run` y `run-backend` buscan primero los JAR en `liquibase_libs/` de AIDA y,
si no hay, en el de la dependencia Zigma (la raíz del repositorio en desarrollo).
Configuran sus rutas absolutas. Un `LIQUIBASE_CLASSPATH` explícito
tiene prioridad; si no hay JAR locales, Liquibase conserva su búsqueda habitual.
Desde otro directorio, indicá el build del ejemplo:

```sh
zig build --build-file /ruta/a/zigma-definition/examples/aida/build.zig run \
  -Dlibpq-prefix=/opt/homebrew/opt/libpq
```

El build por defecto de AIDA instala backend, lanzador y frontend y requiere libpq.
La raíz del repositorio mantiene los comandos de pruebas del framework.

## Compilar o servir el frontend por separado

Desde `examples/aida/`:

```sh
zig build frontend
zig build test-frontend # Node; catálogo, controles y WASM
python3 -m http.server 8000 --bind 127.0.0.1 --directory zig-out/frontend
```

`zig build frontend` instala únicamente `zig-out/frontend/`: WASM, HTML, JavaScript, título
y widgets. Compilar o probar el frontend no requiere libpq ni una base de datos.
Para consultar o modificar filas desde la página debe estar disponible la API.
Podés iniciarla por separado, desde `examples/aida/` y con las mismas variables de conexión:

```sh
zig build run-backend -Dlibpq-prefix=/opt/homebrew/opt/libpq
```

`HTTP_ADDRESS` y `HTTP_PORT` configuran la API (default `127.0.0.1:8080`). Cuando
servís los archivos por separado, `api-config.js` configura `globalThis.ZIGMA_API_BASE`;
si cambiás la URL de la API, ajustá ese archivo en tu despliegue. El lanzador conjunto
resuelve la configuración automáticamente y acepta `FRONTEND_PORT` (default `8000`)
y `ZIGMA_STARTUP_TIMEOUT` (default `120` segundos).

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

## Verificaciones

Desde la raíz, `zig build test-local` prueba Zig, frontend, consumidores, transporte
HTTP y lanzador sin servicios externos. Para probar CRUD, CORS, valores nullable,
fechas y reglas con una base PostgreSQL descartable:

```sh
zig build test-rest-postgres -Dlibpq-prefix=/opt/homebrew/opt/libpq
zig build test-migrations -Dlibpq-prefix=/opt/homebrew/opt/libpq -Dliquibase-bin=/ruta/a/liquibase
```

Las integraciones usan procesos, puertos y bases propios. `test-migrations` también
comprueba el runtime de un consumidor independiente, su frontend y la persistencia
tras reiniciar el backend.

## Archivos principales

| Archivo | Responsabilidad |
| --- | --- |
| `examples/aida/src/aida.zig` | Contrato de AIDA. |
| `examples/aida/src/system.zig` | Adaptador del contrato para el frontend. |
| `examples/aida/src/rest.zig` | Codecs y API de AIDA, compartidos con el servidor PostgreSQL. |
| `examples/aida/src/validation_context.zig` | Obtiene el día civil por solicitud (UTC−03:00 fijo) para validar edad. |
| `examples/aida/src/postgres.zig` | Mappings y artefactos PostgreSQL del contrato. |
| `examples/aida/db/` | Historial de migraciones y snapshot aceptado de AIDA. |
| `src/runtime/launcher.zig` | Lanzador compartido; AIDA lo compone con `addRuntimeFromDep` y lo ejecuta con `zig build run`. |
| `src/server.zig` | Backend compartido con Liquibase, libpq y la API del consumidor. |
| `examples/aida/build.zig` | Build completo de AIDA: frontend, backend, lanzador, migraciones y pruebas del frontend. |
| `src/rest/std_http.zig` | Transporte HTTP compartido y CORS. |
| `src/frontend/` | Cliente WASM y recursos de la página. |

El módulo REST del consumidor publica `Api`. Si `Api.ValidationContext` no es
`void`, también publica `ContextProvider`, inicializable con `.io`, cuyo método
`get()` devuelve el contexto o un error. El servidor toma la fecha una vez por solicitud. Con contexto
`void`, usa automáticamente `std_http.EmptyContextProvider`.

Para ejecutar AIDA con PostgreSQL y migraciones, consultá el [README](../README.md).
