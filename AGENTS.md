# Agent map

Do not scan the repo. Open only the files listed for the task. Design rules, TDD, and Zig 0.17 notes live in `CLAUDE.md` (always loaded). Human how-tos: `README.md`, `docs/build.md`, `docs/run-example.md`, `docs/frontend.md`. Vocabulary walkthrough (leaves → root): `docs/zigma.md`. Named object validators (design, not implemented): `docs/validators.md`.

## Where to look

| Task | Open |
| --- | --- |
| Vocabulary / comptime checks / Def→Info | `src/core/zigma.zig` (one file; does not import generators) |
| Example system (records, entities, `DefinedType`) | `examples/aida/src/aida.zig` |
| Example app (`system` + seeds, own `build.zig`) | `examples/aida/` |
| Positive tests (runtime + comptime asserts) | `test/aida_test.zig` |
| Expected compile failures | `test/compile_errors/<case>.zig` **and** the matching entry in `compile_error_cases` in `build.zig` |
| JSON stringify of record instances / schema | `src/json.zig` + `test/json_test.zig` (+ `test/tiny_system.zig` for the non-aida contract) |
| WASM page | `src/frontend/main.zig`, `src/frontend/main.js`, `src/frontend/index.html` |
| Named object validators (design, not implemented) | `docs/validators.md` |
| Consumer widgets | `examples/aida/src/widgets.js` (optional `widgets_js` on `addAppFromDep`) |
| Consumer page title | optional `title` on `addApp` / `addAppFromDep`; generated `title.js` |
| Backend de pruebas en memoria | `src/testing_backend/main.zig`, `src/testing_backend/memory_repository.zig`, `src/rest/std_http.zig` |
| Comprobación HTTP del backend de pruebas | `test/integration/run_testing_backend.py`, `examples/aida/build.zig` |
| Modules, test graph, `addApp`, wasm/backend steps | `build.zig` |
| Package name, zig version, published paths | `build.zig.zon` |

`src/core/zigma.zig` does not know any concrete system. Generators (`src/json.zig`, `src/testing_backend/`, `src/frontend/`) import `zigma` and an injected `system` module (`type_defs` + `entity_defs`; optional `seeds`). `examples/aida/src/aida.zig` is the vocabulary fixture; `examples/aida/` is a consumer package (`src/system.zig` + `build.zig`) that depends on this framework. Domain names in aida stay in Spanish; framework identifiers are English.

## Public API (`src/core/zigma.zig`)

Search these names; do not read the file top to bottom.

| Name | Role |
| --- | --- |
| `TypeDef` / `common_type_defs` | Domain type (`{ .Type = zig_type }`); builtins `text`, `integer`, `boolean` |
| `defineTypes` | Validate a type collection at the declaration site |
| `record` | `satisfies`: validate a record Def, return it unchanged (literal type kept) |
| `RecordInstanceType` | Zig struct of runtime field values |
| `RecordInfoOf` / `completeRecord` | Def → Info (`is_name: false`, `nullable: true`, label `_`→space, `description: ""`) |
| `FieldInfo` | Completed field shape |
| `merge` / `Merged` | Struct spread; last duplicate wins; first-appearance order |
| `defineEntity` | Local checks (pk/uk/fk **source** fields exist); default empty `fks`/`uks` |
| `defineEntities` | Global fk checks (target entity exists; target fields = full pk or a uk) |
| `extractPk` | Pk fields of an entity as a record (for `merge` into another) |
| `mergePk` | Concat pks, dedup, keep first-appearance order |
| `completeEntity` | Complete fields, dedup pk, normalize fks to source→target maps |

Field Def properties: `type` (required, name in `type_defs`), optional `label`, `nullable`, `is_name` (**only `true`**), `description`. Entity Def: required `fields` + `pk`; optional `fks`, `uks`. Fk `fields`: name list (same names) or source→target map. Fk target is a **string** entity name.

## Generators

`system` contract: `type_defs`, `entity_defs`. Optional `seeds`: struct of row arrays keyed by entity name.

| Module | Root | Role |
| --- | --- | --- |
| `zigma_json` | `src/json.zig` | stringify rows and entity Infos |
| (WASM) | `src/frontend/main.zig` | catalog + typed row builder; import name `system` |
| (Testing backend) | `src/testing_backend/main.zig` | API `/api/{entity}` compartida; repositorio en memoria y transporte `zigma_std_http` |

`addApp` in `build.zig` compiles native HTTP and WASM frontend from one system file, with separate module graphs per target. Consumer (see `examples/aida/build.zig`): `@import("zigma_definition").addAppFromDep(b, dep, .{ .system_root, .rest_root, .aida_root, .widgets_js, .title, .target, .optimize })`. Optional `title` is installed as generated `title.js` (`document.title`).

## Tests

`zig build test` = `test/aida_test.zig` + `test/json_test.zig` + every `compile_error_cases` row.

Adding a rejection: new file under `test/compile_errors/`, then a `{ .file, .expected }` in `build.zig`. Matching is **per line**: full framework `@compileError` text, or `at("file.zig")` for unstable native compiler messages. See `CLAUDE.md` for `/?/` wildcards.

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

`build.zig.zon` `.paths`: `build.zig`, `build.zig.zon`, `src`, `examples`, `README.md`, `LICENSE`. Tests and `docs/` are **not** in the package.
