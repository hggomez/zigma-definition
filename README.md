# zigma-definition

Framework en Zig que deriva tipos, CRUD REST y estructura PostgreSQL desde un contrato
compartido. El repositorio incluye AIDA y [Supermercado](examples/supermercado/README.md) como aplicaciones independientes;
el paquete distribuido del framework no contiene `examples/`.

Esta es la guía de uso. La explicación del contrato, los módulos y las APIs está en
[DOCS.md](DOCS.md). El proyecto se inspira en parte de
[system-definition](https://github.com/ari-dc-uba-ar/system-definition).

Para usar Zigma en otro proyecto, seguí [Crear una aplicación nueva](docs/new-application.md):
un inventario desde cero, con contrato propio, reglas, API, frontend y el recorrido
para incorporar PostgreSQL.

En el contrato AIDA, `Docente`, `Curso` y las demás entidades son tipos Zig generados
desde sus definiciones: pueden usarse directamente en funciones y colecciones.
`Model.Row("docentes")` devuelve ese mismo `Docente`. La composición de record,
definición, tipo y registro se explica en [DOCS.md](DOCS.md#entidades-definición-tipo-concreto-y-registro).
REST utiliza esos tipos en los [validadores de negocio](docs/validators.md):
`validarDocente(Docente, Fecha)` recibe la fila completa y el día de referencia antes
de insertar o actualizar. Para cargo `teorico`, exige cinco años de experiencia,
fecha de nacimiento y al menos treinta años cumplidos. El servidor toma el día
una vez por solicitud con UTC−03:00 fijo; los rechazos de negocio devuelven HTTP 422.

## Requisitos

- Zig `0.17.0-dev.1818+7051f8e73`, según [build.zig.zon](build.zig.zon).
- Para ejecutar AIDA con PostgreSQL: PostgreSQL, headers y biblioteca de **libpq**, y **Liquibase Community
  5.0.4** con un entorno Java compatible y el driver JDBC PostgreSQL.
- Docker para la base local del ejemplo, las integraciones y la aceptación de migraciones.
- Node y Python 3 para `test-local`; `run` usa un lanzador Zig en macOS/Linux
  y no requiere Python. Las pruebas Zig de `test` no requieren Node ni Python.

Comprobá Liquibase y agregá su driver una sola vez:

```sh
liquibase --version                 # Debe informar 5.0.4.
liquibase lpm add postgresql
```

Desde AIDA, `run` y `run-backend` detectan primero los JAR de su propio
`liquibase_libs/`; si no hay, buscan en el `liquibase_libs/` de la dependencia
(la raíz del repositorio durante el desarrollo) y pasan sus rutas absolutas a Liquibase. No importa el
directorio desde el que invoques el build ni la versión en el nombre del JAR.
Si definís `LIQUIBASE_CLASSPATH`, se respeta su valor; usá rutas absolutas porque
Liquibase se ejecuta desde `examples/aida/`. Si no hay JAR locales, se conserva
la búsqueda habitual de la instalación de Liquibase.

Para otros comandos de migración o paquetes consumidores, instalá el driver en
el `lib/` de Liquibase o configurá `LIQUIBASE_CLASSPATH` con su ruta absoluta.

La [instalación de Liquibase en Linux](DOCS.md#instalación-de-liquibase-en-linux) está en
la documentación. Los comandos de la aplicación se ejecutan desde `examples/aida/`;
los comandos de pruebas del framework se ejecutan desde la raíz del repositorio.

Los ejemplos usan `-Dlibpq-prefix=/opt/homebrew/opt/libpq` para macOS con Homebrew.
En Linux podés reemplazar esa opción por rutas independientes, consultadas con `pg_config`:

Desde `examples/aida/`:

```sh
zig build check \
  -Dlibpq-include="$(pg_config --includedir)" \
  -Dlibpq-lib="$(pg_config --libdir)"
```

Las mismas opciones sirven para arrancar el servidor y ejecutar las integraciones.
Cada ruta explícita tiene prioridad sobre la correspondiente del prefijo; la otra sigue
usando el prefijo si está definido. En Ubuntu/Debian, instalá `libpq-dev` para disponer
de los headers y la biblioteca de desarrollo en la máquina donde compilás.

## Comandos habituales

| Directorio | Comando | Uso |
| --- | --- | --- |
| Raíz | `zig build` | Configurar la biblioteca, sin construir aplicaciones ni comprobar schemas. |
| Raíz | `zig build test-local` | Verificar Zig, frontend, transporte HTTP y lanzador; sin PostgreSQL. |
| `examples/aida` | `zig build` | Instalar backend, lanzador y frontend; requiere libpq, sin conectar a la DB. |
| `examples/aida` | `zig build run` | Iniciar backend PostgreSQL y frontend. Requiere conexión y libpq. |
| `examples/aida` | `zig build check` | Compilar aplicación y comprobar su schema sin ejecutarla. |
| `examples/aida` | `zig build check-schema` | Comparar el contrato con el snapshot aceptado. |
| `examples/aida` | `zig build migration` / `zig build accept-migration` | Preparar y verificar un cambio de schema. |

Las opciones de libpq de los ejemplos siguientes se agregan a los comandos que la usan.

## Compilar y probar el frontend

Desde la raíz:

```sh
cd examples/aida
zig build frontend
zig build test-frontend # requiere Node; catálogo, controles y WASM
```

`zig build frontend` instala únicamente `zig-out/frontend/`, sin requerir libpq. Para listar y modificar filas,
la página necesita la API PostgreSQL. El arranque conjunto se describe a continuación;
[la guía del ejemplo](docs/run-example.md) también explica cómo servir el frontend
por separado.

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

Desde `examples/aida/`, usá estas credenciales para la base local anterior, o reemplazalas por las de tu base:

```sh
export DATABASE_URL="postgresql://zigma:secret@localhost:5433/zigma_dev"
export LIQUIBASE_URL="jdbc:postgresql://localhost:5433/zigma_dev"
export LIQUIBASE_USERNAME="zigma"
export LIQUIBASE_PASSWORD="secret"

zig build run -Dlibpq-prefix=/opt/homebrew/opt/libpq
```

El comando compila ambos componentes, inicia el backend real y espera a que aplique las
migraciones aceptadas. Cuando la API está disponible en `http://127.0.0.1:8080/api`, sirve
el frontend: abrí **[http://127.0.0.1:8000](http://127.0.0.1:8000)**. La base debe estar
disponible con la conexión configurada. El historial SQL incorpora los datos iniciales
de demostración una vez; las modificaciones posteriores persisten al reiniciar.
Si el backend falla, el lanzador termina; `Ctrl+C` detiene backend y frontend juntos.
AIDA usa el [lanzador compartido](src/runtime/launcher.zig) y el
[servidor PostgreSQL compartido](src/server.zig), compuestos en
[`examples/aida/build/application.zig`](examples/aida/build/application.zig) mediante `addRuntimeFromDep`.
Una aplicación nueva puede usar `addRuntimeFromDep`; ver la
[guía de adopción](docs/new-application.md#componer-el-servidor-y-el-lanzador).

Podés configurar `HTTP_ADDRESS`, `HTTP_PORT`, `FRONTEND_PORT` (default 8000) y
`LIQUIBASE_SCHEMA`. El frontend recibe automáticamente la URL configurada de la API.
Si Liquibase no está en el PATH, exportá `LIQUIBASE_BIN` con la ruta de su ejecutable.
`ZIGMA_STARTUP_TIMEOUT` permite ajustar los 120 segundos de espera inicial.

Para ejecutar solo el backend, seguí usando `zig build run-backend` con las mismas
opciones de libpq. Para compilar ambos sin iniciarlos:

```sh
zig build check -Dlibpq-prefix=/opt/homebrew/opt/libpq
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

El historial de AIDA está en `examples/aida/db/`. Ejecutá los comandos siguientes
desde `examples/aida/`.

1. Editá las entidades en [examples/aida/src/aida.zig](examples/aida/src/aida.zig) o los mappings SQL en
   [examples/aida/src/postgres.zig](examples/aida/src/postgres.zig).
2. Revisá las diferencias. Si afectan al schema, el comando termina con error y muestra
   una vista previa:

   ```sh
   zig build check-schema
   ```

3. Generá el único borrador pendiente en `examples/aida/db/drafts/`:

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
   zig build -Dlibpq-prefix=/opt/homebrew/opt/libpq
   ```

   La aceptación ejecuta el historial y el borrador en PostgreSQL descartable, verifica su
   estructura y luego mueve el SQL a `examples/aida/db/changes/` y actualiza
   `examples/aida/db/schema.snapshot.json`.
6. Reiniciá AIDA con el comando de arranque para aplicar la migración sobre tu base.

Los archivos aceptados de `examples/aida/db/changes/` se conservan: los cambios siguientes llevan una
migración nueva. Para `accept-migration`, podés indicar un ejecutable específico mediante
`-Dliquibase-bin=/ruta/a/liquibase`.
El coordinador de aceptación está escrito en Zig y vive en
`src/postgres/migrations/tools/`. En macOS/Linux no necesita shell ni utilidades Unix
auxiliares. El arranque de PostgreSQL tiene un límite de 120 segundos, ajustable con
`ZIGMA_MIGRATION_STARTUP_TIMEOUT`; al cancelar, limpia los procesos y recursos temporales.

`init-migrations` se usa una sola vez al crear un historial nuevo. Este repositorio ya
incluye su historial: un clon sobre una base vacía sigue el arranque normal.
Consultá [inicialización y tests](DOCS.md#inicialización-y-tests) para más detalles.

Para aplicar las migraciones aceptadas y terminar sin iniciar HTTP, usá
`zig build apply-migrations` con las mismas variables `LIQUIBASE_*`. Este comando no
requiere libpq; no crea ni acepta borradores.
Tanto este comando como `run` y `run-backend` ejecutan desde `examples/aida/`:
el changelog por defecto sigue siendo `db/changelog-root.yaml`. Las rutas relativas
configuradas por ambiente se resuelven desde allí; usá rutas absolutas para recursos externos.

## Tests

Para ejecutar todas las suites locales desde la raíz (Zig, Node y Python; sin servicios
externos ni libpq):

```sh
zig build test-local
zig build
```

`test-local` incluye `test`, las pruebas del lanzador, la comprobación de comandos del
build, el transporte HTTP con un proveedor controlado, los consumidores independientes
y la suite `test-frontend`. Propaga los fallos de cualquiera de ellas; las integraciones
PostgreSQL comprueban la API con persistencia real.

Para trabajar sobre una parte, siguen disponibles `test` (solo suite Zig y schema),
`test-model`, `test-json` y `test-aida-launcher`. Desde `examples/aida/` también podés
ejecutar sus pruebas sin acceder a los tests privados del framework:

```sh
zig build test                 # dominio, REST, schema y rechazos; sin servicios
zig build test-compile-errors  # los tres rechazos de Cargo
zig build test-frontend        # frontend WASM; requiere Node
zig build test-local           # dominio y frontend
```

Las suites propias y sus fixtures viven en `examples/aida/test/`, se registran en
`examples/aida/build/tests.zig` y forman parte del paquete de la aplicación.
El `test` raíz delega en AIDA conservando target y optimización; `test-local` añade
las integraciones genéricas. `test-aida-classpath` delega al `test-classpath` de AIDA
y requiere libpq.

Compilar la aplicación sin ejecutarla, seleccionando su build desde la raíz:

```sh
zig build --build-file examples/aida/build.zig check -Dlibpq-prefix=/opt/homebrew/opt/libpq
```

`check-backend` conserva la comprobación de compilación exclusiva del backend.

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

Para gestionar un historial PostgreSQL propio, `addMigrationsFromDep` registra los
comandos de migración usando un módulo de tu aplicación que publique `schema_snapshot`
y `baseline_ddl`. Las herramientas y el guard son compartidos; cada aplicación conserva
su directorio `db/`. Ver [el contrato de migraciones](DOCS.md#postgresql-versionado-con-liquibase).

## Licencia

MIT. Ver [LICENSE](LICENSE).
