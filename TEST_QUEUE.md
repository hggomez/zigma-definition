# Cola de ideas de tests

Acá anotamos ideas de tests a medida que surgen en la conversación, para no
perderlas ni implementarlas antes de tiempo. Se sacan de la cola de a una,
en el orden que acordemos en el momento (no necesariamente el de esta
lista), siguiendo TDD: se escribe el test, se muestra en rojo, se espera la
revisión antes de implementar.

Los pasos se corren con `zig build --build-file test/build.zig <paso>`, desde la raíz.

## Pendientes (módulo `sql_generator` — esquema de la base de datos)

* Struct dentro de un struct: no compila (`zig_type_map_sql_nested_struct.zig`), el struct
  interno no tiene dominio que le dé nombre al compuesto.
* Fks cíclicas entre entidades distintas: el test de `sql_generator_test.zig` chequea el
  texto, pero Postgres no lo acepta tal cual (la tabla referenciada tiene que existir en el
  `CREATE TABLE`). Un test contra Postgres lo mostraría.

## Pendientes (módulo `ts_backend_generator` — interfaz de DML en TS)

* Test #2/#3 sobre los builders generados (invariantes que no repiten al generador): un
  `$n` y un valor por columna; orden de `values` = orden de columnas, independiente del
  orden de claves del objeto de entrada.
* Contra Postgres real: violación de uk (`materias.denominacion`) y de fk mapeadas a error
  de dominio, y el rechazo de un valor fuera del intervalo de Zig por un `DOMAIN`
  (`zig_u8`) desde `dml.ts` (el servidor ya chequea los rangos antes de llegar a la base).
* El esquema se aplica sin reset en `create-database` y en el stack de test
  (`Compose.applySchema`): el DDL es `CREATE DOMAIN` / `CREATE TYPE` / `CREATE TABLE` sin
  `IF NOT EXISTS` (Postgres no lo tiene para dominios ni tipos), así que sobre una base ya
  creada tira `already exists` (psql sigue, exit 0, pero ensucia la salida y el test corre
  contra el esquema que ya estaba). `up` sí resetea (`DROP SCHEMA public CASCADE`,
  `ON_ERROR_STOP=1`).
* `type` del `row`/`pk`: usa `,` como separador; TS idiomático es `;` dentro de un type
  literal (ambos válidos).
* Violaciones de pk/uk/fk como errores de dominio (`domainError`, constraints nombradas
  desde el SSOT). Referencia de un intento: commit `5fad670` en
  `lucas-branch-first-attempt`.

## Pendientes (reglas: `defineRules`, `rules_wasm`, `ts_rules_generator`)

* Cuándo se aplica una regla (qué la dispara): ver `PREGUNTAS.md`.
* Reglas de aida: declarar `validarCargo` con `defineRules` (es una función suelta, y
  `cargo` no tiene entidad), y su `.wasm` + `rules.ts` en el backend.
* `RecordInstanceType` ignora `nullable` (un campo nullable es `T`, no `?T`): un `null` en el
  JSON de una regla es `"InvalidInput"` aunque la definición lo permita. Limitación de
  `zigma`, no de WASM; aparece con datos reales. Lo mismo en los tipos de `dml.ts`
  (`cargo: string`, no `string | null`).

## Hechos reglas (referencia rápida, no repetir)

* `zigma.defineRules(type_defs, rule_defs)` (`src/rules.zig`, re-exportado por `zigma`):
  devuelve la colección sin cambios; una regla corre a través de su definición; colección
  vacía (`.{}`, una tupla en este Zig) aceptada (`test/rules_test.zig`).
* No compilan (`test/compile_errors/rules_*`): colección que no es struct, definición que no
  es struct, falta `record`, falta `rule`, propiedad desconocida, `rule` no es función, dos
  parámetros, parámetro de otro record, no es validación (`bool`), devuelve un valor
  (`error{...}!i64`).
* `rules_wasm.run` nativo (`test/rules_wasm_test.zig`): pasa → `""`, cada error de dominio,
  `"InvalidInput"` (no JSON, campo faltante, campo de más, string en entero, `1.5`, `null`),
  rango entero de `i64`; sin leaks (testing allocator).
* `test-rules-wasm`, contra el `.wasm` real desde Node: el contrato a mano
  (`test/rules_wasm_node_test.zig`, incluida la entrada vacía y 10.000 llamadas sin crecer
  la memoria) y el `rules.ts` generado (`test/rules_ts_node_test.zig`).
* `ts_rules_generator`: texto exacto de `ruleFn` (cada tipo de campo, `bigint` dentro de un
  struct, errores ordenados) y de `generateTsRules` (`test/ts_rules_generator_test.zig`).

## Hechos ts_backend_generator (referencia rápida, no repetir)

* `insertFn` / `generateTsBackend`: un builder `INSERT` por entidad, y el módulo entero.
* `selectByPkFn`, `selectAllFn`, `updateFn`, `deleteFn`: los otros builders de DML.
  Cubierto: pk simple y compuesta (`WHERE` y numeración de placeholders `SET`-luego-`WHERE`
  en `update`), `selectAll` sin parámetros, `update` de fila completa, `update` omitido
  para entidades all-pk (`hasNonPkColumns`), cast al compuesto de una columna struct de la
  pk.
* `insertFnTest` .. `deleteFnTest` / `generateTsBackendTests`: el test #1 por builder y el
  módulo de tests entero (imports `node:test`/`node:assert` + import de `./dml.ts`).
* Tipos TS y samples de los tests generados derivados del tipo de Zig de cada dominio
  (`tsTypeOf` vía `type_defs`); dominio que no está en `type_defs` → no compila
  (`ts_type_not_in_type_defs.zig`).
* `test-backend`: genera `dml.ts` + `dml.test.ts` y corre `node --test`.
* `test-backend-db`: `dml.ts` contra Postgres desde el contenedor del backend, para las 11
  entidades (insert, select por pk, select all, update, delete y select por pk vacío), con
  los valores que le pasa `server.ts` (`bigint` 2^53 + 1, `fecha` como literal del
  compuesto, `null`) y las filas como las devuelve `pg`; incluye la fk reflexiva y las pks
  compuestas.

## Hechos sql_generator (referencia rápida, no repetir)

* Columna simple con su tipo SQL (`createTableSql`, un campo).
* Varios campos, cada uno con el tipo SQL que le corresponde.
* Más de una entidad en un mismo esquema (`schemaSql`, entidades
  independientes, sin fk).
* Tipo SQL de cada columna derivado del tipo de Zig de su dominio
  (`sqlTypeOf` vía `type_defs`): `bool` → `BOOLEAN`, `[]const u8` → `TEXT`,
  entero → el entero de Postgres más chico que lo contiene, con un `DOMAIN`
  (`zig_u8`) cuando es más ancho que el de Zig; `i64` → `BIGINT`.
  `schemaSql` emite cada dominio una vez, antes de las tablas.
* Struct (`fecha`) → tipo compuesto con el nombre del dominio, más un `CHECK`
  `<entidad>_<columna>_complete` por columna (el struct entero o `NULL`).
  Orden en `schemaSql`: dominios, compuestos, tablas.
* No compilan (`test/compile_errors/`): dominio que no está en `type_defs`
  (`sql_type_not_in_type_defs.zig`); `zig_type_map_sql_*`: float, opcional,
  otro slice, entero más ancho que `BIGINT` (con y sin signo), struct dentro
  de struct, struct con un campo sin mapeo.
* `NOT NULL` para `nullable: false`, omitido en el default (`aida.alumnos`).
* `PRIMARY KEY` compuesta, todos los campos en orden (fixture ad-hoc
  `combinacion`).
* `UNIQUE` desde `uks` (`aida.materias`).
* `FOREIGN KEY`, mismo nombre origen/destino (fixture ad-hoc `hijo` →
  `padre`).
* `FOREIGN KEY`, columna renombrada / fk reflexiva (fixture ad-hoc
  `persona.jefe`).
* Dos fks distintas a la misma entidad, sin pisarse (fixture ad-hoc
  `disputa` → `objetivo` ×2).
* Fks cíclicas entre dos entidades distintas, sin loopear (fixture ad-hoc
  `nodo_a` ↔ `nodo_b`); confirma también que `zigma.defineEntities` acepta el
  ciclo a nivel framework.
* Pk siempre `NOT NULL`, sin importar el `nullable` del campo (fixture
  `combinacion`, pk `a`,`b`, ninguno con `nullable: false` explícito).
* Esquema completo de aida (`schemaSql` sobre las 11 entidades de
  `aida.entity_defs`, en orden de declaración, al final de
  `test/sql_generator_test.zig`); se ve con
  `zig build print-schema -Dsystem=examples/aida.zig`.
