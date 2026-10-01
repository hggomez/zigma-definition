# Cola de ideas de tests

Acá anotamos ideas de tests a medida que surgen en la conversación, para no
perderlas ni implementarlas antes de tiempo. Se sacan de la cola de a una,
en el orden que acordemos en el momento (no necesariamente el de esta
lista), siguiendo TDD: se escribe el test, se muestra en rojo, se espera la
revisión antes de implementar.

## Pendientes (módulo `sql_generator` — esquema de la base de datos)

Ninguna por ahora: hito 1 (base de datos) completo, ver `GOALS.md`.

## Pendientes (módulo `ts_backend_generator` — interfaz de DML en TS)

* Test #2/#3 sobre los builders generados (invariantes que no repiten al generador): un
  `$n` y un valor por columna; orden de `values` = orden de columnas, independiente del
  orden de claves del objeto de entrada.
* Contra Postgres real (la base es el oráculo, ya no string-assert). Hecho: insert→
  selectByPk ida y vuelta (`periodos`). Falta: `update` toca solo las columnas nombradas,
  `delete` y después selectByPk → vacío, violación de uk (`materias.denominacion`) y de fk
  mapeadas a error de dominio, entidad de pk compuesta (`inscripciones`, necesita
  `cursos`+`alumnos` antes por las fks). En curso: ida y vuelta de `fecha` (test rojo
  escrito, `clases`); se arregla con tipos compuestos de Postgres, ver la decisión en
  `GOALS.md`. Pendientes de esa misma decisión: `fecha` en una pk (`mesas`, keys en otro
  orden), `fecha` nullable en `NULL`, y que la columna sea el compuesto y no `TEXT`.
* `bigint` en el backend: `integer` es `i64` → `BIGINT` / `bigint`. Falta registrar
  `pg.types.setTypeParser(20, BigInt)` en el backend (hoy `pg` devuelve `BIGINT` como
  `string`) y un test de integración que lo muestre (ida y vuelta de un `orden`).
* Caso "no compila": sample TS para un tipo de Zig sin sample (`f32` detrás de un
  dominio) → `"type 'f32' has no TS sample"`.
* Caso "no compila": un sistema que nombra un tipo de dominio igual que un primitivo de
  Zig (`.u8`, `.bool`, …) → `@compileError` propio en `defineTypes`. Hoy no hay colisión
  real (el mapa de primitivos, `zig_type_map_sql.sql_type_defs` / `zig_type_map_ts.ts_type_defs`,
  está separado del mapa de dominio del sistema), pero es confuso y queremos prohibirlo.
* Los tipos TS generados ignoran `nullable` (`insertCursos` declara `docente: string`
  aunque es nullable): deberían ser `T | null`.
* `apply_aida_schema` (usado por `create-database` y `ts-backend-db`) no es idempotente:
  el DDL es `CREATE TABLE`, no `CREATE TABLE IF NOT EXISTS`, así que re-correrlo sobre una
  base ya creada tira `relation "x" already exists` (psql sigue igual, exit 0, pero
  ensucia la salida). Ver si conviene `IF NOT EXISTS` o un `DROP ... CASCADE` previo.
* `type` del `row`/`pk`: usa `,` como separador; TS idiomático es `;` dentro de un type
  literal (ambos válidos).

## Hechos ts_backend_generator (referencia rápida, no repetir)

* `insertFn` / `generateTsBackend`: un builder `INSERT` por entidad, y el módulo entero.
* `selectByPkFn`, `selectAllFn`, `updateFn`, `deleteFn`: los otros builders de DML.
  Cubierto: pk simple y compuesta (`WHERE` y numeración de placeholders `SET`-luego-`WHERE`
  en `update`), `selectAll` sin parámetros, `update` de fila completa, `update` omitido
  para entidades all-pk (`hasNonPkColumns`).
* `insertFnTest` .. `deleteFnTest` / `generateTsBackendTests`: el test #1 por builder y el
  módulo de tests entero (imports `node:test`/`node:assert` + import de `./dml.ts`).
* Tipos TS resueltos desde `type_defs` con `zig_type_map_ts.tsType`; samples de los tests
  derivados del tipo de Zig (`muestra`: slice, `i64` → `1n`, bool, struct → objeto).
* `zig build ts-backend`: genera `dml.ts` + `dml.test.ts` y corre `node --test`.

## Hechos (referencia rápida, no repetir)

* Columna simple con su tipo SQL (`createTableSql`, un campo).
* Varios campos, cada uno con el tipo SQL que le corresponde.
* Más de una entidad en un mismo esquema (`schemaSql`, entidades
  independientes, sin fk).
* Mapeo de todos los tipos de dominio del sistema a SQL, incluyendo uno
  respaldado por un struct anidado (`fecha`) — mapea a una sola columna
  opaca, sin necesitar que `sql_generator.zig` mire el `Type` de Zig
  subyacente.
* `NOT NULL` para `nullable: false`, omitido en el default (`aida.alumnos`).
* `PRIMARY KEY` compuesta, todos los campos en orden (fixture ad-hoc
  `combinacion`; ya funcionaba de antes gracias al `pkClause` genérico).
* `UNIQUE` desde `uks` (`aida.materias`).
* `FOREIGN KEY`, mismo nombre origen/destino (fixture ad-hoc `hijo` →
  `padre`).
* `FOREIGN KEY`, columna renombrada / fk reflexiva (fixture ad-hoc
  `persona.jefe`).
* Dos fks distintas a la misma entidad, sin pisarse (fixture ad-hoc
  `disputa` → `objetivo` ×2).
* Fks cíclicas entre dos entidades distintas, sin loopear ni requerir que
  la tabla referenciada ya exista (fixture ad-hoc `nodo_a` ↔ `nodo_b`);
  de paso confirma que `zigma.defineEntities` acepta el ciclo a nivel
  framework.
* Tipo sin mapeo SQL no compila (`test/compile_errors/
  sql_unknown_type_mapping.zig`, mensaje `"type 'x' has no SQL mapping"`).
* Resolución de tipos (`test/zig_type_map_test.zig`): primitivos por `@typeName` (incl.
  `i64` → `BIGINT`/`bigint`), dominios a través de su tipo de Zig (`email`), struct →
  compuesto en SQL / objeto en TS; no compilan: `f32`, dominio sobre `f32`, nombre
  inexistente.
* Pk siempre `NOT NULL`, sin importar el `nullable` del campo (fixture
  `combinacion`, pk `a`,`b`, ninguno con `nullable: false` explícito).
* Esquema completo de aida (`schemaSql` sobre las 11 entidades de
  `aida.entity_defs`, en orden de declaración) — sostiene el "ver
  corriendo" de este hito (`zig build print-schema`).
