# Cola de ideas de tests

Acá anotamos ideas de tests a medida que surgen en la conversación, para no
perderlas ni implementarlas antes de tiempo. Se sacan de la cola de a una,
en el orden que acordemos en el momento (no necesariamente el de esta
lista), siguiendo TDD: se escribe el test, se muestra en rojo, se espera la
revisión antes de implementar.

## Pendientes (módulo `sql_generator` — esquema de la base de datos)

* Struct anidado dentro de un struct de dominio (por ejemplo un campo `Punto` dentro de
  otro struct): hoy `createTypeSql` tipa cada campo con `sqlType(type_defs,
  @typeName(campo))` y un struct anidado da `type 'x.Y' has no SQL mapping`. Para
  soportarlo: emitir también el `CREATE TYPE` del struct interno (antes que el externo)
  y usarlo como tipo del campo; del lado TS, `tsType` y los samples ya lo resuelven
  recursivamente. Pendiente hasta que aparezca un caso real.

## Pendientes (módulo `ts_backend_generator` — interfaz de DML en TS)

* Test #2/#3 sobre los builders generados (invariantes que no repiten al generador): un
  `$n` y un valor por campo hoja (una columna respaldada por un struct toma uno por campo); orden de `values` = orden de columnas, independiente del
  orden de claves del objeto de entrada.
* Contra Postgres real (la base es el oráculo, ya no string-assert). Hecho: insert→
  selectByPk ida y vuelta (`periodos`). Falta: `update` toca solo las columnas nombradas,
  `delete` y después selectByPk → vacío, violación de uk (`materias.denominacion`) y de fk
  mapeadas a error de dominio, entidad de pk compuesta (`inscripciones`, necesita
  `cursos`+`alumnos` antes por las fks). Hecho también: ida y vuelta de `fecha`
  (`clases`, tipo compuesto + codec en SQL), `fecha` en la pk de `mesas` (select y delete
  con las keys del objeto en otro orden), `fecha` nullable en `NULL` (insert y update), y
  un `integer` (`i64`) más allá de 2^53 vuelve como el `bigint` exacto (pool con
  `pgTypes`).
* `bigint` y JSON: `JSON.stringify` no serializa un `bigint` (tira `TypeError`). Va a
  importar en la capa HTTP: decidir cómo viaja (string, número si entra, etc.).
* Soporte real de un campo con parser (`i64`) dentro de un struct de dominio. Hoy no
  compila a propósito (`test/compile_errors/ts_struct_field_needs_parser.zig`): el struct
  se decodifica con `to_jsonb` y `pg` lo parsea con `JSON.parse`, sin pasar por los
  parsers de `pgTypes`, así que un `i64` volvería como `number` con pérdida de precisión.
  Opción pensada: en el `SELECT`, mandar esos campos como texto dentro del JSON
  (`jsonb_build_object('f', ("col")."f"::text, …)`, con `CASE WHEN "col" IS NULL`) y
  generar un decoder TS por entidad que aplique `BigInt(...)` (cambia la forma de los
  builders: `{ text, values, decode }` o `decode<E>Row`). Descartado: un reviver en el
  parser de `jsonb`, porque el tipo dependería del tamaño del valor. Pendiente hasta un
  caso real.
* `pgTypes` vale para todo `BIGINT` del pool, no solo las columnas de aida: un
  `count(*)` escrito a mano vuelve como `BigInt` (`5n`). Consistente, pero hay que
  saberlo.
* Arrays de `BIGINT` (OID 1016) no tienen parser en `ts_parser_defs`; ninguna columna los
  usa hoy.
* Los scripts de integración que no son el de `bigint` crean el pool sin
  `types: pgTypes(pg.types)`; el backend real siempre tiene que usarlo.
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
* Codec de columnas respaldadas por un struct en el texto SQL: encode
  `ROW($n::T, …)::<compuesto>` (con `CASE WHEN … IS NULL` si es nullable y no pk), un
  placeholder por campo hoja; decode `to_jsonb(col) AS col`. Los `SELECT` listan las
  columnas (ya no `SELECT *`). Fixtures `lugar` (struct nullable fuera de la pk) y `marca`
  (struct como pk).
* `pgTypesFn`: `pgTypes(defaults)` al principio de `dml.ts`, el `types` por pool de
  `pg.Pool` con los parsers de `zig_type_map_ts.ts_parser_defs` (`i64` → OID 20 →
  `BigInt`), cayendo a los defaults de `pg`.
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
* Un campo con parser (`i64`) dentro de un struct de dominio no compila
  (`ts_struct_field_needs_parser.zig`, chequeo en `StructOf` de `ts_backend_generator`).
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
