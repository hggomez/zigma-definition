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
| [build/app.zig](../build/app.zig) | `addApp` / `addAppFromDep`: backend en memoria, WASM y archivos estáticos para consumidores. |
| [build/aida.zig](../build/aida.zig) | Servidor real, lanzador, comprobación del snapshot y comandos de migración. |
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
const run_aida_rest_server = b.addRunArtifact(aida_rest_server);
aida_rest_server_step.dependOn(&run_aida_rest_server.step);
check_aida_rest_server_step.dependOn(&aida_rest_server.step);
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
build, y una única invocación de `test-backend test-frontend` en el consumidor AIDA.
Usa el mismo compilador y conserva target, CPU y optimización. No requiere libpq,
Docker, PostgreSQL ni Liquibase, y propaga cualquier fallo.

Los pasos específicos siguen disponibles: `test` conserva las suites Zig de contrato,
modelo, JSON, REST, PostgreSQL sin servicios, migraciones, rechazos de compilación y
snapshot; `test-model` y `test-json` ejecutan subconjuntos. Ninguno de esos tres requiere
Node o Python. Las integraciones `test-postgres`, `test-rest-postgres` y `test-migrations`
son separadas y usan PostgreSQL descartable; la última también requiere Liquibase.

## Example app

The aida demo is a **consumer** of this package (`examples/aida/build.zig.zon` uses a path dependency). From that directory:

```sh
cd examples/aida
zig build              # zig-out/frontend/ + zig-out/bin/testing-backend
zig build frontend     # WASM page only
zig build testing-backend # run the in-memory testing backend (port 8080)
zig build test-backend    # HTTP integration check (Python 3; own process and port)
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
mismo compilador. La entrada de la aplicación, `examples/aida/src/main.zig`, se compila
como `aida-launcher`: espera la API, sirve los archivos y cierra ambos con Ctrl+C en
macOS/Linux. `examples/aida/src/server.zig` sigue siendo la entrada del ejecutable
`aida-rest-server`. Solo `test-aida-launcher` requiere Python 3 para sus procesos
simulados; el ejecutable que se prueba es el mismo que utiliza `run-aida`.

## What the library build graph contains

| Step | Command | Result |
| --- | --- | --- |
| install (default) | `zig build` | módulos y comprobación del schema; sin binarios de la app |
| `run-aida` | `zig build run-aida` | aplicación PostgreSQL y frontend |
| `check-aida` | `zig build check-aida` | compilar aplicación y lanzador sin ejecutarlos |
| `test-local` | `zig build test-local` | suite Zig, frontend, backend en memoria, lanzador y comandos |
| `test` | `zig build test` | suite Zig y schema; sin Node ni Python |
| `apply-migrations` | `zig build apply-migrations` | aplicar el historial aceptado y terminar, sin HTTP |

`run-aida-rest` y `check-aida-rest` conservan las operaciones exclusivas del backend.
`check-schema`, `migration` y `accept-migration` forman el flujo de cambios de schema;
`init-migrations` inicializa una sola vez el historial de un sistema nuevo.
El bootstrap DDL es un auxiliar de integración y no tiene un paso público de arranque.

Módulos principales publicados por `build.zig`:

- `zigma` → `src/core/zigma.zig` (exported; leaf)
- `zigma_json` → `src/json.zig` (exportado; recibe Model y utiliza std.json)
- `aida` → `examples/aida/src/aida.zig` (exported fixture; imports `zigma`)

`addApp` / `addAppFromDep` se implementan en `build/app.zig` y se reexportan desde
`build.zig`. Los llama el build del **consumidor**, no el `build()` raíz del framework.
Componen `testing-backend` (HTTP compartido + REST + repositorio en memoria) y el
frontend WASM, con instancias de módulos separadas para cada target.

List every step:

```sh
zig build --help
```

## Using this repo as a dependency

```sh
zig fetch --save git+https://github.com/ari-dc-uba-ar/zigma-definition.git#v0.1.0
```

Vocabulary only:

```zig
const zigma = b.dependency("zigma_definition", .{}).module("zigma");
exe.root_module.addImport("zigma", zigma);
```

Generate backend + frontend from a `system` file (`type_defs` + `entity_defs`).

`entity_defs` es el registro de asociaciones `.Type` + `.definition` validado por
`zigma.defineEntities`. El contrato AIDA expone esos tipos como `Docente`, `Curso`, etc.;
los seeds usan arrays de los mismos tipos. El consumidor sigue inyectando las dos
propiedades habituales, sin necesitar exponer un `Model` adicional:

```zig
const zigma_def = b.dependency("zigma_definition", .{});
const zigma_build = @import("zigma_definition");
_ = zigma_build.addAppFromDep(b, zigma_def, .{
    .system_root = b.path("src/system.zig"),
    .rest_root = b.path("src/rest.zig"),
    .aida_root = b.path("src/aida.zig"),
    .widgets_js = b.path("src/widgets.js"), // optional
    .title = "aida", // optional; browser tab, generated `title.js`
    .target = target,
    .optimize = optimize,
});
```

In-tree, `examples/aida/` does the same with `.path = "../.."`.

The package also exports `aida` (`examples/aida/src/aida.zig`) and `zigma_json`.

The returned `App` exposes `testing_backend`, `run_testing_backend`, and `frontend`.
`PackageFiles` supplies `testing_backend` and `std_http` separately.
