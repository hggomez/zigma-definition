# Build del proyecto

Los comandos siguientes se ejecutan desde la raíz. Usá la versión de Zig indicada en
`minimum_zig_version` de `build.zig.zon`.

## Cómo leer el build

Empezá por [build.zig](../build.zig). Su función `build(b)` elige target y optimización,
crea los módulos compartidos, declara la aplicación AIDA y conecta las suites de tests.
Las implementaciones están separadas por responsabilidad:

| Archivo | Qué buscar allí |
| --- | --- |
| [build.zig](../build.zig) | Opciones generales, API pública y comportamiento de `zig build` sin argumentos. |
| [build/modules.zig](../build/modules.zig) | Bibliotecas publicadas, imports entre módulos y opciones de libpq. |
| [build/app.zig](../build/app.zig) | `addApp` / `addAppFromDep`: frontend WASM y archivos estáticos para consumidores. |
| [build/migrations.zig](../build/migrations.zig) | `addMigrations` / `addMigrationsFromDep`: herramientas, guard y comandos de migración del consumidor. |
| [build/runtime.zig](../build/runtime.zig) | `addRuntime` / `addRuntimeFromDep`: backend PostgreSQL y lanzador compartidos. |
| [build/aida.zig](../build/aida.zig) | Composición de AIDA con los helpers de runtime y migraciones. |
| [build/tests.zig](../build/tests.zig) | Suites, integración con servicios y lista de rechazos de compilación esperados. |

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

Por ejemplo, en `build/aida.zig` ambos comandos reutilizan el mismo ejecutable:

```zig
b.step("run-aida-rest", "Iniciar el backend").dependOn(&runtime.run_backend.step);
b.step("check-aida-rest", "Compilar el backend").dependOn(&runtime.backend.step);
```

`run-aida-rest` necesita compilar **y ejecutar** el servidor. `check-aida-rest` solo
depende de su compilación. El orden textual de estas líneas no ordena las tareas:
las dependencias lo hacen; las ramas independientes pueden correr en paralelo.

El paso por defecto de la raíz depende del guard de compilación y de la comprobación
del snapshot. `test-local` agrega las suites locales, mientras que las integraciones
PostgreSQL pertenecen a ramas separadas. Por eso declarar libpq en `modules.zig` no
obliga a tenerlo instalado para ejecutar los tests locales.

`Modules` y `Artifacts` agrupan referencias a nodos ya creados para reutilizarlos.
Los archivos de `build/` son auxiliares del programa de build; no son nuevos módulos
runtime del framework. La API pública sigue en `build.zig`, incluido `addAppFromDep`.
El backend nativo y el frontend WASM conservan grafos de módulos separados porque
usan targets distintos.

Las rutas también conservan su dueño: `b.path("src/...")` se refiere al paquete que
posee `b`, aunque la función esté escrita en `build/app.zig`. `dep.path("src/...")`
se refiere al paquete de la dependencia. `build/` está incluido en los archivos
publicados de `build.zig.zon` para que estos helpers estén disponibles fuera del repo.

## Default build (the library)

```sh
zig build
```

Exporta módulos y comprueba el snapshot aceptado de AIDA; no compila la aplicación.
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

`test-runtime` crea otro paquete independiente y prueba `addRuntimeFromDep`, el
lanzador y la inicialización de su historial sin libpq. `test-runtime-backend` requiere
libpq, comprueba el guard y los fallos de migración y se incluye en `test-rest-postgres`.
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
zig build              # zig-out/frontend/
zig build frontend     # WASM page only
zig build test-frontend   # catálogo, controles y WASM real (Node)
```

How to run it in a browser: [run-example.md](run-example.md).

Para el backend real con PostgreSQL, desde la raíz del repositorio:

```sh
zig build run-aida -Dlibpq-prefix=/opt/homebrew/opt/libpq
zig build check-aida -Dlibpq-prefix=/opt/homebrew/opt/libpq # solo compilar
zig build test-aida-launcher # procesos simulados; sin PostgreSQL
```

`run-aida` requiere las variables de conexión del [README](../README.md), sin Python.
El build compila el backend real y ejecuta el paso `frontend` del consumidor AIDA con el
mismo compilador. `build/aida.zig` usa `addRuntime`: `src/runtime/launcher.zig` produce
`aida-launcher`, que espera la API, sirve los archivos y cierra ambos con Ctrl+C en
macOS/Linux; `src/server.zig` produce `aida-backend`, que aplica migraciones
y atiende la API. `ZIGMA_STARTUP_TIMEOUT` configura la espera inicial.
`test-aida-launcher` usa Python para simular procesos y prueba el mismo lanzador.

## What the library build graph contains

| Step | Command | Result |
| --- | --- | --- |
| install (default) | `zig build` | módulos y comprobación del schema; sin binarios de la app |
| `run-aida` | `zig build run-aida` | aplicación PostgreSQL y frontend |
| `check-aida` | `zig build check-aida` | compilar aplicación y lanzador sin ejecutarlos |
| `test-local` | `zig build test-local` | suite Zig, frontend, HTTP, lanzador y comandos |
| `test` | `zig build test` | suite Zig y schema; sin Node ni Python |
| `apply-migrations` | `zig build apply-migrations` | aplicar el historial aceptado y terminar, sin HTTP |

`run-aida-rest` y `check-aida-rest` conservan las operaciones exclusivas del backend.
`check-schema`, `migration` y `accept-migration` forman el flujo de cambios de schema;
`init-migrations` inicializa una sola vez el historial de un sistema nuevo.
En este repositorio esos comandos gestionan `examples/aida/db/`: `build/aida.zig`
pasa `examples/aida/` como `project_root` al helper de migraciones. `run-aida` y
`run-aida-rest` también se ejecutan desde ese directorio, por lo que el changelog
conserva su ruta lógica `db/changelog-root.yaml`.
El bootstrap DDL es un auxiliar de integración y no tiene un paso público de arranque.

El paquete raíz publica explícitamente los archivos de build, `src/` y `db/` de AIDA
en `.paths`, para excluir sus cachés y binarios generados. El paquete AIDA incluye
`db` en su propio `build.zig.zon`.

Módulos principales publicados por `build.zig`:

- `zigma` → `src/core/zigma.zig` (exported; leaf)
- `zigma_json` → `src/json.zig` (exportado; recibe Model y utiliza std.json)
- `aida` → `examples/aida/src/aida.zig` (exported fixture; imports `zigma`)

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

The package also exports `aida` (`examples/aida/src/aida.zig`) and `zigma_json`.

El resultado `App` expone `frontend`, `frontend_directory` y `frontend_step`. Los dos últimos conectan los archivos instalados
a `addRuntimeFromDep`, respetando el prefijo de instalación elegido con `--prefix`.
`PackageFiles` describe únicamente las fuentes y recursos del frontend.
