# Running the backend and example frontend

The example is a **separate package** under `examples/aida/` that depends on this framework. It produces a WASM page with one spreadsheet-like table per aida entity (nav + hash, e.g. `#materias`). Column headers and the empty alta row come from `completeEntity` Infos in the WASM catalog. A Zig server keeps an in-memory list per entity (optional `system.seeds` plus POSTs/PUTs/DELETEs) and prints writes. Nothing is written to disk.

How that page is produced (build vs runtime catalog → DOM): [frontend.md](frontend.md).

Work from `examples/aida/`. You need **two terminals** (backend on 8080, page on 8000) and then a browser. The page cannot be opened as `file://` — the browser must `fetch` the WASM module.

## Quick start

**Terminal 1 — backend** (from `examples/aida/`, leave it running):

```sh
cd examples/aida
zig build backend
```

(`zig build dummy` is the same step.) You should see `backend running on port 8080...`

**Terminal 2 — page:**

```sh
cd examples/aida
zig build frontend
python3 -m http.server 8000 --directory zig-out/frontend
```

**Browser:** open <http://localhost:8000/>. After WASM loads, a nav of entity names appears and the first catalog entity is shown (in aida, `docentes`), then filled from `GET /{entity}`, plus an empty row at the bottom. Open `#materias` for that table (labels `materia` / `denominación`). Fill that last row and click **New**. The backend should print the JSON, the new row should appear in the table, and the last row should be empty again for the next alta. **Save** on an existing row sends `PUT /{entity}?pk…` and replaces that row (pk cells are locked). **Delete** sends `DELETE /{entity}?pk…` with no body. Other entities are the same at `#docentes`, `#clases`, etc. The lists live in the backend process only (restarting it restores the seeds).

Every entity is seeded with at least two rows (FKs point at those pks). Restarting the backend restores the seeds.

## 1. Build the frontend

```sh
cd examples/aida
zig build frontend
```

(`zig build` does the same install, plus the backend binary.) That writes `examples/aida/zig-out/frontend/` with:

- `index.html` — shell (nav + empty table; JS fills them from the WASM catalog)
- `title.js` — generated `document.title` from `addAppFromDep` `.title` (`"aida"`)
- `main.js` — reads the entity catalog from WASM, builds the table, `GET`/`POST /{entity}`, `PUT`/`DELETE /{entity}?pk…`
- `widgets.js` — aida’s domain-type widgets (`fecha` → date picker); optional for other consumers
- `frontend.wasm` — catalog from `completeEntity` of every entity in `src/system.zig`, typed row builder, JSON via `stringifyRecord`

The WASM/JS sources themselves still live in the framework package (`src/frontend/`); `addAppFromDep` compiles them. The consumer may pass `widgets_js` to install a `widgets.js` map next to `main.js`, and `title` to generate `title.js` (`document.title`; aida uses `"aida"`).

## 2. Backend

```sh
cd examples/aida
zig build backend
```

Or, after `zig build`, run the installed binary:

```sh
./zig-out/bin/backend
```

It listens on `http://localhost:8080`. CORS is enabled so the page on another origin can call it.

- `GET /{entity}` returns the in-memory list for that entity as a JSON array. `src/system.zig` seeds every entity with at least two rows. Other GET paths are `404`.
- `POST /{entity}` prints the request, parses a record instance, appends it, and answers `{"status": "received"}`.
- `PUT /{entity}?k=v&…` prints the request, replaces the row whose pk matches the query (body pk must match; every pk field required), and answers `{"status": "received"}` (or 404 if that pk is missing).
- `DELETE /{entity}?k=v&…` prints the request, removes the row whose pk matches the query (no body; full pk required), and answers `{"status": "received"}` (or 404 if that pk is missing).

Leave this running.

## 3. Run the frontend

On WASM load, `main.js` reads `schema_ptr`/`schema_len` (the entity catalog), builds the nav and the selected table, then fetches that entity's list. **New** packs the empty-row values into WASM memory and calls `create_row`, which builds a typed record instance and POSTs JSON. **Save** on a tbody row calls `build_row` and `PUT`s `/{entity}?pk…` (pk cells are locked). **Delete** sends `DELETE /{entity}?pk…` with no body. On success the page GETs the list again. Serve that directory (a second terminal, still under `examples/aida/`):

```sh
python3 -m http.server 8000 --directory zig-out/frontend
```

Open <http://localhost:8000/> (or `http://localhost:8000/index.html`).

If the table stays empty, check that the backend is on 8080 and that WASM loaded (status should leave “Loading...”). If the POST never appears, check that `zig-out/frontend/frontend.wasm` is the file you just built, and that the static server is serving `application/wasm` for `.wasm` (Python’s `http.server` usually does).

The library `zig build` at the repo root does **not** install this app.

## Layout

| Piece | Role |
| --- | --- |
| `examples/aida/src/aida.zig` | domain Defs only (also the library test fixture) |
| `examples/aida/src/system.zig` | `system` for generators: aida Defs + demo seeds |
| `examples/aida/src/widgets.js` | domain type → widget (`fecha` date picker) |
| `examples/aida/build.zig` | consumer: `addAppFromDep` (`.title = "aida"`) |
| `src/frontend/main.zig` | WASM: catalog + row builder; `system` is injected at build |
| `src/json.zig` | JSON for rows and entity Infos |
| `src/frontend/main.js` | nav + table from the catalog; `GET`/`POST /{entity}`, `PUT`/`DELETE /{entity}?pk` |
| `src/frontend/index.html` | shell: nav, empty table + status; loads generated `title.js` |
| `src/http/main.zig` | in-memory `GET`/`POST /{entity}`, `PUT`/`DELETE /{entity}?pk` from `system` |
