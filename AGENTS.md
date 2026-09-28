# Agent map

Do not scan the repo. Open only the files listed for the task. Design rules, TDD, and Zig 0.17 notes live in `CLAUDE.md` (always loaded). Human how-tos: `README.md`, `docs/build.md`, `docs/run-example.md`, `docs/frontend.md`. Vocabulary walkthrough (leaves → root): `docs/zigma.md`. Named object validators (design, not implemented): `docs/validators.md`.

## Where to look

| Task | Open |
| --- | --- |
| API pública del núcleo | `src/core/zigma.zig` (reexporta las implementaciones; no importa generadores) |
| Tipos de dominio / records / campos / merge | `src/core/records.zig`, `test/aida_test.zig`, `test/model_nullability_test.zig` |
| Entidades / PK, UK y FK / metadatos de reglas | `src/core/entities.zig`, `test/aida_test.zig` |
| System / Model.info / tipos derivados | `src/core/model.zig`, `test/system_model_test.zig`, `test/model_consumers_test.zig` |
| Helpers internos de nombres | `src/core/names.zig` |
| Example system (records, entities, `DefinedType`) | `examples/aida/src/aida.zig` |
| Example app (`system` + seeds, own `build.zig`) | `examples/aida/` |
| Positive tests (runtime + comptime asserts) | `test/aida_test.zig` |
| Expected compile failures | `test/compile_errors/<case>.zig` **and** the matching entry in `compile_error_cases` in `build/tests.zig` |
| JSON stringify of record instances / schema | `src/json.zig` + `test/json_test.zig` (+ `test/tiny_system.zig` for the non-aida contract) |
| Catálogo basado en Model / nulabilidad / pruebas WASM | `test/json_model_test.zig`, `test/integration/run_frontend_test.mjs`, `test/integration/frontend_review.md`, `examples/aida/build.zig` |
| WASM page | `src/frontend/main.zig`, `src/frontend/main.js`, `src/frontend/index.html` |
| Named object validators (design, not implemented) | `docs/validators.md` |
| Consumer widgets | `examples/aida/src/widgets.js` (optional `widgets_js` on `addAppFromDep`) |
| Consumer page title | optional `title` on `addApp` / `addAppFromDep`; generated `title.js` |
| API REST / routing / secuencia CRUD | `src/rest/api.zig`, `src/rest/types.zig`, `test/rest_test.zig` |
| Entrada y salida REST / codecs | `src/rest/request.zig`, `src/rest/response.zig`, `src/rest/codecs.zig`, `test/rest_test.zig` |
| Validadores REST actuales | `src/rest/validation.zig`, `examples/aida/src/rest.zig`, `test/aida_rest_test.zig`, `test/rest_test.zig` |
| Backend de pruebas en memoria | `src/testing_backend/main.zig`, `src/testing_backend/memory_repository.zig`, `src/rest/std_http.zig` |
| Comprobación HTTP del backend de pruebas | `test/integration/run_testing_backend.py`, `examples/aida/build.zig` |
| Arranque conjunto del backend real y frontend | `tools/run_aida.zig`, `test/integration/run_aida_test.py`, `build/aida.zig`, `src/frontend/api_config.js` |
| AIDA PostgreSQL y aplicación del historial | `examples/aida/src/postgres.zig`, `examples/aida/src/server.zig`, `tools/apply_migrations.zig` |
| API de migraciones / snapshot canónico | `src/postgres/migrations/schema.zig`, `src/postgres/migrations/snapshot.zig` |
| Diff, nombres y drafts SQL de migraciones | `src/postgres/migrations/diff.zig`, `src/postgres/migrations/draft.zig`, `test/postgres_migrations_test.zig` |
| Bootstrap exclusivo de integraciones / comandos públicos | `test/integration/postgres_bootstrap.zig`, `test/integration/build_commands_test.py`, `build/tests.zig`, `build/aida.zig` |
| Entrada del build / módulos publicados / libpq | `build.zig`, `build/modules.zig`, `docs/build.md` |
| `addApp`, `addAppFromDep`, WASM/backend del consumidor | `build/app.zig`, `examples/aida/build.zig` |
| Grafo de tests locales e integraciones | `build/tests.zig` |
| Package name, zig version, published paths | `build.zig.zon` |

`src/core/zigma.zig` does not know any concrete system. Generators (`src/json.zig`, `src/testing_backend/`, `src/frontend/`) import `zigma` and an injected `system` module (`type_defs` + `entity_defs`; optional `seeds`). `examples/aida/src/aida.zig` is the vocabulary fixture; `examples/aida/` is a consumer package (`src/system.zig` + `build.zig`) that depends on this framework. Domain names in aida stay in Spanish; framework identifiers are English.

## Public API (`src/core/zigma.zig`)

Buscar estos nombres en su implementación; `zigma.zig` conserva la entrada pública.
Los helpers compartidos entre archivos del núcleo no se reexportan.

| Nombre | Implementación en `src/core/` | Responsabilidad |
| --- | --- | --- |
| `TypeDef` / `common_type_defs` | `records.zig` | Tipo de dominio no opcional; tipos base `text`, `integer`, `boolean` |
| `defineTypes` | `records.zig` | Valida la colección de tipos en su declaración |
| `record` | `records.zig` | Valida una Def y conserva su tipo literal |
| `RecordInstanceType` | `records.zig` | Instancia con `T` o `?T` según el record, sin restricciones de entidad |
| `RecordInfoOf` / `completeRecord` | `records.zig` | Def → Info; explicita defaults de campos |
| `FieldInfo` | `records.zig` | Forma normalizada de un campo |
| `merge` / `Merged` | `records.zig` | Combina structs: gana el último valor; orden de primera aparición |
| `defineEntity` | `entities.zig` | Comprueba PK, UK, origen de FK y reglas; completa colecciones omitidas |
| `defineEntities` | `entities.zig` | Comprueba destinos de FK y correspondencia con PK o UK completas |
| `extractPk` / `mergePk` | `entities.zig` | Extrae campos PK / combina claves sin duplicados |
| `completeEntity` | `entities.zig` | Normaliza campos, PK no-null, mapas FK y dependencias de reglas |
| `RuleInfo` | `entities.zig` | Dependencias serializables de una regla, sin implementación |
| `System` | `model.zig` | Construye `Model.info` y genera `Row`, `Projection`, `Patch`, `Filters`, `RuleInput` |

Field Def properties: `type` (required, name in `type_defs`), optional `label`, `nullable`, `is_name` (**only `true`**), `description`. Entity Def: required `fields` + `pk`; optional `fks`, `uks`, `rules`. Fk `fields`: name list (same names) or source→target map. Fk target is a **string** entity name. Cada regla declara una lista `fields`; su binding y ejecución automática siguen fuera del núcleo.

## Generators

`system` contract: `type_defs`, `entity_defs`. Optional `seeds`: struct of row arrays keyed by entity name.

| Module | Root | Role |
| --- | --- | --- |
| `zigma_json` | `src/json.zig` | serializa filas y el catálogo desde Model.info + Model.Row; publica nullable |
| (WASM) | `src/frontend/main.zig` | catalog + typed row builder; import name `system` |
| (Testing backend) | `src/testing_backend/main.zig` | API `/api/{entity}` compartida; repositorio en memoria y transporte `zigma_std_http` |

`addApp` is implemented in `build/app.zig` and reexported by `build.zig`. It compiles native HTTP and WASM frontend from one system file, with separate module graphs per target. Consumer (see `examples/aida/build.zig`): `@import("zigma_definition").addAppFromDep(b, dep, .{ .system_root, .rest_root, .aida_root, .widgets_js, .title, .target, .optimize })`. Optional `title` is installed as generated `title.js` (`document.title`).

## Tests

`zig build test` ejecuta las suites Zig de contrato, modelo, JSON, REST, PostgreSQL sin
servicios, herramientas de migración, rechazos de compilación y comprobación del snapshot.
`zig build test-local` agrega el lanzador, los nombres públicos de comandos y las suites
del consumidor `test-backend` y `test-frontend`; requiere Node y Python, pero no libpq
ni servicios externos.

Adding a rejection: new file under `test/compile_errors/`, then a `{ .file, .expected }` in `build/tests.zig`. Matching is **per line**: full framework `@compileError` text, or `at("file.zig")` for unstable native compiler messages. See `CLAUDE.md` for `/?/` wildcards.

TDD: write the failing test first, show the red, **wait for review before implementing**.

## Demo

The library `zig build` does **not** install the example app. From `examples/aida/`:

```sh
zig build              # zig-out/frontend/ + zig-out/bin/testing-backend
zig build testing-backend # run the in-memory testing backend (port 8080)
zig build test-backend    # HTTP integration check (Python 3)
python3 -m http.server 8000 --directory zig-out/frontend
```

Details: [docs/run-example.md](docs/run-example.md).

WASM exports: `schema_ptr`, `schema_len`, `input_ptr`, `input_len`, `lengths_ptr`, `json_ptr`, `json_len`, `error_ptr`, `error_len`, `build_row`, `create_row`. JS import: `env.js_send_post`. El frontend arma la página desde el catálogo de entidades y consulta `/api/{entity}`. POST crea filas; PUT envía los campos editables sin PK y usa la query para seleccionar filas; DELETE usa esos mismos filtros. La API compartida determina validaciones y respuestas. `testing-backend` carga los seeds en `MemoryRepository` y delega HTTP/CORS a `std_http.serve`. Los datos solo duran mientras vive el proceso.

## Published package

`build.zig.zon` `.paths`: `build.zig`, `build.zig.zon`, `build/`, `src`, `examples`, `db`, `tools`,
`test/integration`, `README.md`, `DOCS.md`, `LICENSE`. Los tests unitarios y `docs/` no
forman parte del paquete; los auxiliares de integración sí.
