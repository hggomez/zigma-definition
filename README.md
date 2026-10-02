# zigma-definition

Framework en Zig que deriva tipos, CRUD REST y estructura PostgreSQL desde un contrato
compartido. Incluye AIDA como aplicación de ejemplo.

Esta es la guía de uso. La explicación del contrato, los módulos y las APIs está en
[DOCS.md](DOCS.md). El proyecto es un port de
[system-definition](https://github.com/ari-dc-uba-ar/system-definition).

## Requisitos

- Zig `0.17.0-dev.1818+7051f8e73`, según [build.zig.zon](build.zig.zon).
- Para ejecutar AIDA con PostgreSQL: PostgreSQL, headers y biblioteca de **libpq**, y **Liquibase Community
  5.0.4** con un entorno Java compatible y el driver JDBC PostgreSQL.
- Docker para la base local del ejemplo, las integraciones y la aceptación de migraciones.
- Node y Python 3 para `test-local`; `run-aida` usa un lanzador Zig en macOS/Linux
  y no requiere Python. Las pruebas Zig de `test` no requieren Node ni Python.

Comprobá Liquibase y agregá su driver una sola vez:

```sh
liquibase --version                 # Debe informar 5.0.4.
liquibase lpm add postgresql
```

La [instalación de Liquibase en Linux](DOCS.md#instalación-de-liquibase-en-linux) está en
la documentación. Todos los comandos siguientes se ejecutan desde la raíz del repositorio.

Los ejemplos usan `-Dlibpq-prefix=/opt/homebrew/opt/libpq` para macOS con Homebrew.
En Linux podés reemplazar esa opción por rutas independientes, consultadas con `pg_config`:

```sh
zig build check-aida \
  -Dlibpq-include="$(pg_config --includedir)" \
  -Dlibpq-lib="$(pg_config --libdir)"
```

Las mismas opciones sirven para arrancar el servidor y ejecutar las integraciones.
Cada ruta explícita tiene prioridad sobre la correspondiente del prefijo; la otra sigue
usando el prefijo si está definido. En Ubuntu/Debian, instalá `libpq-dev` para disponer
de los headers y la biblioteca de desarrollo en la máquina donde compilás.

## Comandos habituales

| Comando desde la raíz | Uso |
| --- | --- |
| `zig build run-aida` | Iniciar backend PostgreSQL y frontend. Requiere conexión y libpq. |
| `zig build check-aida` | Compilar aplicación y lanzador sin ejecutarlos. Requiere libpq. |
| `zig build test-local` | Verificar Zig, frontend, backend en memoria y lanzador; sin PostgreSQL. |
| `zig build check-schema` | Comparar el contrato con el snapshot aceptado. |
| `zig build migration` / `zig build accept-migration` | Preparar y verificar un cambio de schema. |

Las opciones de libpq de los ejemplos siguientes se agregan a los comandos que la usan.

## Alternativa: backend de pruebas en memoria

Este entorno usa la API REST de AIDA y sus seeds; solo necesita Zig. Desde la raíz:

```sh
cd examples/aida
zig build testing-backend
```

Escucha en `http://127.0.0.1:8080/api` y descarta los cambios al terminar. Podés configurar
`HTTP_ADDRESS` y `HTTP_PORT`.
Para compilar y abrir el frontend, consultá [la guía del ejemplo](docs/run-example.md).

La comprobación HTTP usa un proceso y puerto propios y requiere Python 3:

```sh
zig build test-backend
zig build test-frontend # requiere Node; catálogo, controles y WASM
```

## Arrancar AIDA con PostgreSQL

### 1. Preparar una base vacía

Si ya tenés PostgreSQL y una base vacía, usá sus datos de conexión en el paso siguiente.
Para crear una base local con Docker:

```sh
docker run -d \
  --name zigma-dev \
  -p 127.0.0.1:5433:5432 \
  -e POSTGRES_DB=zigma_dev \
  -e POSTGRES_USER=zigma \
  -e POSTGRES_PASSWORD=secret \
  postgres:18.4-alpine3.24

docker exec zigma-dev pg_isready -U zigma -d zigma_dev
```

Esperá a que `pg_isready` informe que acepta conexiones. Si el contenedor ya existe y está
apagado, inicialo con `docker start zigma-dev`.

### 2. Configurar la conexión e iniciar backend y frontend

Usá estas credenciales para la base local anterior, o reemplazalas por las de tu base:

```sh
export DATABASE_URL="postgresql://zigma:secret@localhost:5433/zigma_dev"
export LIQUIBASE_URL="jdbc:postgresql://localhost:5433/zigma_dev"
export LIQUIBASE_USERNAME="zigma"
export LIQUIBASE_PASSWORD="secret"

zig build run-aida -Dlibpq-prefix=/opt/homebrew/opt/libpq
```

El comando compila ambos componentes, inicia el backend real y espera a que aplique las
migraciones aceptadas. Cuando la API está disponible en `http://127.0.0.1:8080/api`, sirve
el frontend: abrí **[http://127.0.0.1:8000](http://127.0.0.1:8000)**. No carga seeds de
prueba ni inicia PostgreSQL: la base debe estar disponible con la conexión configurada.
Si el backend falla, el lanzador termina; `Ctrl+C` detiene backend y frontend juntos.
La entrada de la aplicación es [`examples/aida/src/main.zig`](examples/aida/src/main.zig).

Podés configurar `HTTP_ADDRESS`, `HTTP_PORT`, `FRONTEND_PORT` (default 8000) y
`LIQUIBASE_SCHEMA`. El frontend recibe automáticamente la URL configurada de la API.
Si Liquibase no está en el PATH, exportá `LIQUIBASE_BIN` con la ruta de su ejecutable.
`AIDA_STARTUP_TIMEOUT` permite ajustar los 120 segundos de espera inicial.

Para ejecutar solo el backend, seguí usando `zig build run-aida-rest` con las mismas
opciones de libpq. Para compilar ambos sin iniciarlos:

```sh
zig build check-aida -Dlibpq-prefix=/opt/homebrew/opt/libpq
```

### 3. Probar la API

Desde otra terminal:

```sh
curl http://127.0.0.1:8080/api/materias

curl -X POST http://127.0.0.1:8080/api/materias \
  -H 'Content-Type: application/json' \
  -d '{"materia":"m1","denominacion":"Álgebra"}'
```

Para apagar el servidor, usá `Ctrl+C`. Volvé a ejecutar el comando de arranque para aplicar
las nuevas migraciones aceptadas.

## Cambiar el contrato

1. Editá las entidades en [examples/aida/src/aida.zig](examples/aida/src/aida.zig) o los mappings SQL en
   [examples/aida/src/postgres.zig](examples/aida/src/postgres.zig).
2. Revisá las diferencias. Si afectan al schema, el comando termina con error y muestra
   una vista previa:

   ```sh
   zig build check-schema
   ```

3. Generá el único borrador pendiente en `db/drafts/`:

   ```sh
   zig build migration
   ```

   Para elegir su nombre, usá `zig build migration -Dname=nombre_del_cambio` en lugar del
   comando anterior. Si no hay diferencias de schema, no se crea una migración.
4. Revisá el SQL y resolvé los comentarios `ZIGMA-BLOCKER` escribiendo las operaciones
   necesarias antes de retirar sus marcadores. Conservá los hashes del borrador.
5. Verificá y aceptá el cambio:

   ```sh
   zig build accept-migration -Dlibpq-prefix=/opt/homebrew/opt/libpq
   zig build
   ```

   La aceptación ejecuta el historial y el borrador en PostgreSQL descartable, verifica su
   estructura y luego mueve el SQL a `db/changes/` y actualiza `db/schema.snapshot.json`.
6. Reiniciá AIDA con el comando de arranque para aplicar la migración sobre tu base.

Los archivos aceptados de `db/changes/` se conservan: los cambios siguientes llevan una
migración nueva. Para `accept-migration`, podés indicar un ejecutable específico mediante
`-Dliquibase-bin=/ruta/a/liquibase`.

`init-migrations` se usa una sola vez al crear un historial nuevo. Este repositorio ya
incluye su historial: un clon sobre una base vacía sigue el arranque normal.
Consultá [inicialización y tests](DOCS.md#inicialización-y-tests) para más detalles.

Para aplicar las migraciones aceptadas y terminar sin iniciar HTTP, usá
`zig build apply-migrations` con las mismas variables `LIQUIBASE_*`. Este comando no
requiere libpq; no crea ni acepta borradores.

## Pendiente de revisión: `fecha`

El dominio AIDA define `Fecha` como struct Zig `{ año, mes, día }`
([examples/aida/src/aida.zig](examples/aida/src/aida.zig)). Eso es la forma canónica del
tipo; no es un string ISO.

Hoy el cableado HTTP/JSON ↔ PostgreSQL queda así (revisar si conviene unificarlo):

| Capa | Forma |
| --- | --- |
| Dominio / WASM / JSON de fila | objeto `{"año","mes","día"}` |
| Codec de wire | [examples/aida/src/fecha_wire.zig](examples/aida/src/fecha_wire.zig): objeto ↔ texto `YYYY-MM-DD` **sin** validar el calendario civil |
| PostgreSQL | columna `DATE` (texto ISO hacia libpq) |
| UI | [examples/aida/src/widgets.js](examples/aida/src/widgets.js) convierte el objeto a `<input type="date">` y viceversa |

El controlador REST ([examples/aida/src/rest.zig](examples/aida/src/rest.zig)) solo registra el
codec; no implementa reglas de `Fecha`. Una fecha civil inválida puede pasar el codec y
fallar recién en PostgreSQL.

**Preguntas abiertas:** ¿el JSON público debería ser siempre el objeto de dominio, o ISO?
¿la validación civil pertenece al dominio, al codec, a la base, o a ninguna de esas capas?
¿hace falta un codec genérico para structs de dominio en lugar de uno ad hoc por tipo?

## Tests

Para ejecutar todas las suites locales desde la raíz (Zig, Node y Python; sin servicios
externos ni libpq):

```sh
zig build test-local
zig build
```

`test-local` incluye `test`, las pruebas del lanzador, la comprobación de comandos del
build y las suites `test-backend` y `test-frontend` del consumidor. Propaga los fallos
de cualquiera de ellas; no reemplaza las integraciones PostgreSQL.

Para trabajar sobre una parte, siguen disponibles `test` (solo suite Zig y schema),
`test-model`, `test-json` y `test-aida-launcher`. Desde `examples/aida/` también podés
ejecutar `test-backend` o `test-frontend` por separado.

Compilar la aplicación sin ejecutarla:

```sh
zig build check-aida -Dlibpq-prefix=/opt/homebrew/opt/libpq
```

`check-aida-rest` conserva la comprobación de compilación exclusiva del backend.

Integraciones con PostgreSQL descartable; requieren Docker y libpq. La última también
requiere Liquibase 5.0.4:

```sh
zig build test-postgres -Dlibpq-prefix=/opt/homebrew/opt/libpq
zig build test-rest-postgres -Dlibpq-prefix=/opt/homebrew/opt/libpq
zig build test-migrations -Dlibpq-prefix=/opt/homebrew/opt/libpq
```

## Usar el framework en otro proyecto

Consultá [la configuración como dependencia](DOCS.md#usar-como-dependencia) y
[los tipos derivados del contrato](DOCS.md#modelo-compartido-y-tipos-generados).

## Licencia

MIT. Ver [LICENSE](LICENSE).
