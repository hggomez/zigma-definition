# Building the project

From the repository root. Zig **0.17.0-dev** or newer is required (`minimum_zig_version` in `build.zig.zon`).

## Default build (the library)

```sh
zig build
```

Exports modules; does not compile the example app. Generators live in this package so a consumer can call `addAppFromDep`.

## Tests

```sh
zig build test
```

Runs:

- runtime tests in `test/aida_test.zig` (the aida fixture against the `zigma` vocabulary)
- runtime tests in `test/json_test.zig` (JSON writer; aida plus `test/tiny_system.zig`)
- expected compile-error cases in `test/compile_errors/` (the step succeeds only if the compiler error matches `build.zig`)

## Example app

The aida demo is a **consumer** of this package (`examples/aida/build.zig.zon` uses a path dependency). From that directory:

```sh
cd examples/aida
zig build              # zig-out/frontend/ + zig-out/bin/backend
zig build frontend     # WASM page only
zig build backend      # run the HTTP server (port 8080; `dummy` is an alias)
```

How to run it in a browser: [run-example.md](run-example.md).

## What the library build graph contains

| Step | Command | Result |
| --- | --- | --- |
| install (default) | `zig build` | package modules only (no demo binaries) |
| `test` | `zig build test` | runtime tests + expected compile errors |

Modules wired in the library `build.zig`:

- `zigma` → `src/zigma.zig` (exported; leaf)
- `zigma_json` → `src/json.zig` (exported; imports `zigma`)
- `aida` → `examples/aida/src/aida.zig` (exported fixture; imports `zigma`)

`addApp` / `addAppFromDep` are called from a **consumer** `build.zig`, not from this package’s `build()`. They compile native HTTP and WASM frontend with **separate** `zigma` / `zigma_json` / `system` module instances per target.

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

Generate backend + frontend from a `system` file (`type_defs` + `entity_defs`):

```zig
const zigma_def = b.dependency("zigma_definition", .{});
const zigma_build = @import("zigma_definition");
_ = zigma_build.addAppFromDep(b, zigma_def, .{
    .system_root = b.path("src/system.zig"),
    .widgets_js = b.path("src/widgets.js"), // optional
    .title = "aida", // optional; browser tab, generated `title.js`
    .target = target,
    .optimize = optimize,
});
```

In-tree, `examples/aida/` does the same with `.path = "../.."`.

The package also exports `aida` (`examples/aida/src/aida.zig`) and `zigma_json`.
