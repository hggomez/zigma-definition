# Build del proyecto

Los comandos del framework se ejecutan desde la raíz; los de AIDA, desde
`examples/aida/`. Usá la versión de Zig indicada en
`minimum_zig_version` de `build.zig.zon`.

## Cómo leer el build

Empezá por [build.zig](../build.zig). Su función `build(b)` elige target y optimización,
crea los módulos del framework y conecta las suites de tests. El build completo de
AIDA pertenece a [examples/aida/build.zig](../examples/aida/build.zig).
Las implementaciones están separadas por responsabilidad:

| Archivo | Qué buscar allí |
| --- | --- |
| [build.zig](../build.zig) | Opciones generales, API pública y comportamiento de `zig build` sin argumentos. |
| [build/modules.zig](../build/modules.zig) | Bibliotecas del framework, imports entre módulos y opciones de libpq; no registra AIDA. |
| [build/app.zig](../build/app.zig) | `addApp` / `addAppFromDep`: frontend WASM y archivos estáticos para consumidores. |
| [build/migrations.zig](../build/migrations.zig) | `addMigrations` / `addMigrationsFromDep`: herramientas, guard y comandos de migración del consumidor. |
| [build/runtime.zig](../build/runtime.zig) | `addRuntime` / `addRuntimeFromDep`: backend PostgreSQL y lanzador compartidos. |
| [examples/aida/build/application.zig](../examples/aida/build/application.zig) | Módulos de AIDA y composición de sus comandos con los helpers de runtime y migraciones. |
| [build/tests.zig](../build/tests.zig) | Suites, integración con servicios y lista de rechazos de compilación esperados. |
| [build/test_fixtures.zig](../build/test_fixtures.zig) | Módulos privados de AIDA y herramientas que necesitan las pruebas; no registra comandos de aplicación. |

`build()` es un programa Zig que **describe un grafo de tareas**. Crear un nodo con
`addExecutable` no inicia el servidor ni compila inmediatamente todo el proyecto.
Después de describir el grafo, Zig ejecuta los nodos necesarios para el comando elegido.

| Concepto | Función dentro del grafo |
| --- | --- |
| `b.createModule(...)` | Describe fuentes, target, optimización e imports de un módulo interno. |
| `b.addModule("zigma", ...)` | Además publica ese módulo para que otro paquete lo obtenga con `.module("zigma")`. |
| `b.addExecutable(...)` / `b.addTest(...)` | Declara la compilación de un ejecutable o una suite de tests. |
| `b.addRunArtifact(exe)` | Declara la ejecución de un artefacto y depende de su compilación. |
| `b.step("nombre", "descripción")` | Crea un comando público, seleccionable con `zig build nombre`. |
| `paso.dependOn(otro)` | Expresa que `otro` debe completarse antes que `paso`. |

Por ejemplo, en `examples/aida/build/application.zig` ambos comandos reutilizan el mismo ejecutable:

```zig
b.step("run-backend", "Iniciar el backend").dependOn(&runtime.run_backend.step);
b.step("check-backend", "Compilar el backend").dependOn(&runtime.backend.step);
```

`run-backend` necesita compilar **y ejecutar** el servidor. `check-backend` solo
depende de su compilación. El orden textual de estas líneas no ordena las tareas:
las dependencias lo hacen; las ramas independientes pueden correr en paralelo.

El paso por defecto de la raíz configura la biblioteca sin comprobar snapshots.
El build por defecto de AIDA instala frontend, backend y lanzador, y comprueba su
snapshot sin conectar a la DB. `test-local` agrega las suites locales, mientras que las integraciones
PostgreSQL pertenecen a ramas separadas. Por eso declarar libpq en `modules.zig` no
obliga a tenerlo instalado para ejecutar los tests locales.

`build/modules.zig` publica únicamente módulos del framework. La composición del
ejemplo crea sus módulos privados usando la dependencia `zigma_definition` y llama
a `addAppFromDep`, `addMigrationsFromDep` y `addRuntimeFromDep`. Las suites crean
sus fixtures por separado; `aida`, `aida_rest` y `aida_postgres` ya no son módulos
publicados por la biblioteca.

`Modules` y `Artifacts` agrupan referencias a nodos ya creados para reutilizarlos.
Los archivos de `build/` son auxiliares del programa de build; no son nuevos módulos
runtime del framework. La API pública sigue en `build.zig`, incluido `addAppFromDep`.
El backend nativo y el frontend WASM conservan grafos de módulos separados porque
usan targets distintos.

Las rutas también conservan su dueño: `b.path("src/...")` se refiere al paquete que
posee `b`, aunque la función esté escrita en `build/app.zig`. `dep.path("src/...")`
se refiere al paquete de la dependencia. `build/` está incluido en los archivos
publicados de `build.zig.zon` para que estos helpers estén disponibles fuera del repo.
En el build del ejemplo, `b.path` apunta a AIDA y `dep.path` al framework.
Frontend, backend y migraciones se componen en un mismo grafo, sin un segundo
`zig build` para generar el frontend.

## Default build (the library)

```sh
zig build
```

Exporta módulos sin comprobar el snapshot ni compilar AIDA. Funciona también si
el paquete no contiene `examples/`.
Los generadores permiten que un consumidor componga su build con `addAppFromDep`.

## Tests

```sh
zig build test-local # todas las suites locales; requiere Node y Python
```

`test-local` ejecuta la suite Zig `test`, las pruebas del lanzador y de los comandos del
build, consumidores independientes, transporte HTTP y `test-frontend` en AIDA.
Usa el mismo compilador; el frontend siempre usa WASM y optimización `.small`. No requiere libpq,
Docker, PostgreSQL ni Liquibase, y propaga cualquier fallo.

También incluye `test-migration-tool`: prueba el workflow de archivos con un inventario
independiente y crea un paquete temporal que usa `addMigrationsFromDep` desde cero.
Comprueba inicialización, borradores, hashes, bloqueos y el guard de compilación;
la invocación de Liquibase se sustituye por un ejecutable de prueba en esta suite local.
También ejecuta el coordinador Zig de aceptación con Docker, Liquibase y validador
simulados: comprueba el orden de aceptación, rutas con espacios, ejecución sin utilidades
de shell, timeout, interrupciones y limpieza. Las fuentes viven en
`src/postgres/migrations/tools/` y se distribuyen dentro de `src`.

`test-runtime` crea otro paquete independiente y prueba `addRuntimeFromDep`, el
lanzador y la inicialización de su historial sin libpq. `test-runtime-backend` requiere
libpq, comprueba el guard y los fallos de migración y se incluye en `test-rest-postgres`.
`test-aida-classpath` también requiere libpq y está incluido en `test-rest-postgres`:
usa Liquibase simulado para comprobar la detección de JAR desde distintos directorios,
las rutas con espacios, la prioridad del classpath explícito y cambios de drivers
sin limpiar cachés. No necesita Java, Liquibase ni una base de datos.
`test-migrations` también arranca el runtime genérico con Liquibase y PostgreSQL reales,
verifica frontend, CRUD persistente e idempotencia al reiniciar solo el backend.

Los pasos específicos siguen disponibles: `test` conserva las suites Zig de contrato,
modelo, JSON, REST, PostgreSQL sin servicios, migraciones, rechazos de compilación y
snapshot; `test-model` y `test-json` ejecutan subconjuntos. Ninguno de esos tres requiere
Node o Python. Las integraciones `test-postgres`, `test-rest-postgres` y `test-migrations`
son separadas y usan PostgreSQL descartable; la última también requiere Liquibase.
`test-migrations` incluye la aceptación desde un paquete independiente: rechaza SQL
que produce un catálogo incorrecto, conserva su historial y luego acepta el draft
corregido. El caso usa un directorio de historial propio, con espacios en su ruta.

## Example app

The aida demo is a **consumer** of this package (`examples/aida/build.zig.zon` uses a path dependency). From that directory:

```sh
cd examples/aida
zig build -Dlibpq-prefix=/opt/homebrew/opt/libpq # frontend/ y bin/; sin ejecutar
zig build frontend     # WASM page only
zig build test-frontend   # catálogo, controles y WASM real (Node)
```

How to run it in a browser: [run-example.md](run-example.md).

Para el backend real con PostgreSQL, desde `examples/aida/`:

```sh
zig build run -Dlibpq-prefix=/opt/homebrew/opt/libpq
zig build check -Dlibpq-prefix=/opt/homebrew/opt/libpq # solo compilar
```

`run` requiere las variables de conexión del [README](../README.md), sin Python.
El build compila el backend real y el frontend en el mismo grafo.
`examples/aida/build/application.zig` usa `addRuntimeFromDep`: `src/runtime/launcher.zig` produce
`aida-launcher`, que espera la API, sirve los archivos y cierra ambos con Ctrl+C en
macOS/Linux; `src/server.zig` produce `aida-backend`, que aplica migraciones
y atiende la API. `ZIGMA_STARTUP_TIMEOUT` configura la espera inicial.
Desde la raíz, `test-aida-launcher` usa Python para simular procesos y prueba el mismo lanzador.

## What the library build graph contains

| Directorio | Comando | Resultado |
| --- | --- | --- |
| Raíz | `zig build` | configurar módulos de la biblioteca; sin aplicación ni schema |
| Raíz | `zig build test-local` | suite Zig, frontend, HTTP, lanzador y comandos |
| Raíz | `zig build test` | suite Zig y snapshot del fixture; sin Node ni Python |
| `examples/aida` | `zig build` | instalar frontend, backend y lanzador; comprobar el schema |
| `examples/aida` | `zig build run` | aplicación PostgreSQL y frontend |
| `examples/aida` | `zig build check` | compilar aplicación y comprobar schema sin ejecutarla |
| `examples/aida` | `zig build apply-migrations` | aplicar el historial aceptado y terminar, sin HTTP |

`run-backend` y `check-backend` conservan las operaciones exclusivas del backend.
`check-schema`, `migration` y `accept-migration` forman el flujo de cambios de schema;
`init-migrations` inicializa una sola vez el historial de un sistema nuevo.
En este repositorio esos comandos gestionan `examples/aida/db/` desde el build
del ejemplo. `project_root` usa su valor por defecto: la raíz de AIDA. `run` y
`run-backend` también se ejecutan desde ese directorio, por lo que el changelog
conserva su ruta lógica `db/changelog-root.yaml`.
`examples/aida/build/application.zig` busca primero los JAR de `liquibase_libs/` de AIDA
y, si no hay, los del directorio de la dependencia (la raíz del repositorio durante
el desarrollo). Agrega sus rutas absolutas al ambiente de ambos
comandos de arranque mediante rutas absolutas, salvo que ya exista un
`LIQUIBASE_CLASSPATH` explícito. La detección se repite en cada invocación del build;
los artefactos compilados siguen usando su caché. Si falta el directorio o está
vacío, no se modifica el classpath de Liquibase.
El bootstrap DDL es un auxiliar de integración y no tiene un paso público de arranque.

El paquete del framework excluye `examples/` de `.paths`. Conserva los helpers,
las fuentes y las herramientas genéricas de migración, además de los auxiliares
de integración. AIDA publica su propio `build/`, `src/` y `db/`.

Módulos principales publicados por `build.zig`:

- `zigma` → `src/core/zigma.zig` (exported; leaf)
- `zigma_json` → `src/json.zig` (exportado; recibe Model y utiliza std.json)
- `zigma_rest` → `src/rest/api.zig` (API compartida)

`addApp` / `addAppFromDep` se implementan en `build/app.zig` y se reexportan desde
`build.zig`. Los llama el build del **consumidor**, no el `build()` raíz del framework.
Compilan e instalan el frontend WASM (`wasm32-freestanding`, `.small`).
La ejecución nativa se compone con `addRuntimeFromDep`, que recibe target y optimización.

List every step:

```sh
zig build --help
```

## Using this repo as a dependency

Para un proyecto completo con contrato propio, seguí
[Crear una aplicación nueva](new-application.md). También podés fijar una dependencia
remota a un commit o tag existente que contenga las APIs necesarias:

```sh
zig fetch --save 'git+https://github.com/ari-dc-uba-ar/zigma-definition.git#<revision>'
```

Reemplazá `<revision>` por esa revisión; los ejemplos de esta documentación corresponden
al árbol actual del proyecto.

Vocabulary only:

```zig
const zigma = b.dependency("zigma_definition", .{}).module("zigma");
exe.root_module.addImport("zigma", zigma);
```

Generate the frontend from a `system` file (`type_defs` + `entity_defs`).

`entity_defs` es el registro de asociaciones `.Type` + `.definition` validado por
`zigma.defineEntities`. El contrato AIDA expone esos tipos como `Docente`, `Curso`, etc.;
el consumidor sigue inyectando las dos
propiedades habituales, sin necesitar exponer un `Model` adicional:

```zig
const zigma_def = b.dependency("zigma_definition", .{});
const zigma_build = @import("zigma_definition");
_ = zigma_build.addAppFromDep(b, zigma_def, .{
    .system_root = b.path("src/system.zig"),
    .contract_root = b.path("src/aida.zig"),
    .widgets_js = b.path("src/widgets.js"), // optional
    .title = "aida", // optional; browser tab, generated `title.js`
});
```

In-tree, `examples/aida/` does the same with `.path = "../.."`.

`contract_root` se expone como `@import("contract")` a `system_root` en el grafo WASM. Si se omite, el helper usa `system_root` como raíz del contrato.

El paquete exporta `zigma_json`; el contrato de cada aplicación se crea en su propio build.

El resultado `App` expone `frontend`, `frontend_directory` y `frontend_step`. Los dos últimos conectan los archivos instalados
a `addRuntimeFromDep`, respetando el prefijo de instalación elegido con `--prefix`.
`PackageFiles` describe únicamente las fuentes y recursos del frontend.
