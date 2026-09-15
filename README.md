# zigma-definition

Framework en Zig que deriva tipos, CRUD REST y estructura PostgreSQL desde un contrato
compartido. Incluye AIDA como aplicación de ejemplo.

Esta es la guía de uso. La explicación del contrato, los módulos y las APIs está en
[DOCS.md](DOCS.md). El proyecto es un port de
[system-definition](https://github.com/ari-dc-uba-ar/system-definition).

## Requisitos

- Zig `0.17.0-dev.1818+7051f8e73`, según [build.zig.zon](build.zig.zon).
- Para ejecutar AIDA: PostgreSQL, headers y biblioteca de **libpq**, y **Liquibase Community
  5.0.4** con un entorno Java compatible y el driver JDBC PostgreSQL.
- Docker para la base local del ejemplo, las integraciones y la aceptación de migraciones.

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
zig build check-aida-rest \
  -Dlibpq-include="$(pg_config --includedir)" \
  -Dlibpq-lib="$(pg_config --libdir)"
```

Las mismas opciones sirven para arrancar el servidor y ejecutar las integraciones.
Cada ruta explícita tiene prioridad sobre la correspondiente del prefijo; la otra sigue
usando el prefijo si está definido. En Ubuntu/Debian, instalá `libpq-dev` para disponer
de los headers y la biblioteca de desarrollo en la máquina donde compilás.

## Arrancar AIDA

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

### 2. Configurar la conexión e iniciar el servidor

Usá estas credenciales para la base local anterior, o reemplazalas por las de tu base:

```sh
export DATABASE_URL="postgresql://zigma:secret@localhost:5433/zigma_dev"
export LIQUIBASE_URL="jdbc:postgresql://localhost:5433/zigma_dev"
export LIQUIBASE_USERNAME="zigma"
export LIQUIBASE_PASSWORD="secret"

zig build run-aida-rest -Dlibpq-prefix=/opt/homebrew/opt/libpq
```

El servidor aplica las migraciones aceptadas pendientes y luego escucha en
`http://127.0.0.1:8080` con CORS permisivo para el frontend de ejemplo. Si una migración
falla, el arranque se detiene. Al clonar el repositorio con su historial completo, este
mismo comando construye la base desde cero.

Podés configurar `HTTP_ADDRESS`, `HTTP_PORT` y `LIQUIBASE_SCHEMA`. Si Liquibase no está en
el PATH, exportá `LIQUIBASE_BIN` con la ruta de su ejecutable.

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

1. Editá las entidades en [examples/aida.zig](examples/aida.zig) o los mappings SQL en
   [examples/aida_postgres.zig](examples/aida_postgres.zig).
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

`init-migrations` y `baseline-existing` se usan al crear un historial nuevo o adoptar una
base preexistente. Un clon de este repositorio sobre una base vacía sigue el arranque normal.
Consultá [inicialización y adopción](DOCS.md#inicialización-adopción-y-tests) para esos casos.

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

Sin servicios externos:

```sh
zig build test-model
zig build test
zig build
```

Compilar el servidor sin ejecutarlo:

```sh
zig build check-aida-rest -Dlibpq-prefix=/opt/homebrew/opt/libpq
```

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
