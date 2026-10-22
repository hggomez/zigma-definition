# Cola de ideas de tests

Acá anotamos ideas de tests a medida que surgen en la conversación, para no
perderlas ni implementarlas antes de tiempo. Se sacan de la cola de a una,
en el orden que acordemos en el momento (no necesariamente el de esta
lista), siguiendo TDD: se escribe el test, se muestra en rojo, se espera la
revisión antes de implementar.

## Pendientes (módulo `sql_generator` — esquema de la base de datos)

Hito 1 (base de datos) completo, ver `GOALS.md`. Queda una limitación conocida:

* Struct dentro de un struct: hoy no compila (`zig_type_map_sql_nested_struct.zig`), el
  struct interno no tiene dominio que le dé nombre al compuesto.

## Pendientes (módulo `ts_backend_generator` — interfaz de DML en TS)

* Test #2/#3 sobre los builders generados (invariantes que no repiten al generador): un
  `$n` y un valor por columna; orden de `values` = orden de columnas, independiente del
  orden de claves del objeto de entrada.
* Contra Postgres real (la base es el oráculo, ya no string-assert). Hecho: insert→
  selectByPk ida y vuelta (`periodos`). Falta: `update` toca solo las columnas nombradas,
  `delete` y después selectByPk → vacío, violación de uk (`materias.denominacion`) y de fk
  mapeadas a error de dominio, `fecha` ida y vuelta por su columna de tipo compuesto (hoy
  se rompe: `pg` recibe el objeto crudo), un campo `bigint` (`i64`, p. ej. `clases.orden`)
  y uno con `DOMAIN` (rechazo de un valor fuera del intervalo de Zig), entidad de pk
  compuesta (`inscripciones`, necesita `cursos`+`alumnos` antes por las fks).
* `apply_aida_schema` (usado por `create-database` y `ts-backend-db`) no es idempotente:
  el DDL es `CREATE DOMAIN` / `CREATE TYPE` / `CREATE TABLE` sin `IF NOT EXISTS`, así que
  re-correrlo sobre una base ya creada tira `type "x" already exists` / `relation "x"
  already exists` (psql sigue igual, exit 0, pero ensucia la salida, y el test corre contra
  el esquema viejo sin avisar). `CREATE DOMAIN` / `CREATE TYPE` no tienen `IF NOT EXISTS`
  en Postgres, así que probablemente convenga un reset previo (`DROP SCHEMA public
  CASCADE`, ver el último punto).
* `type` del `row`/`pk`: usa `,` como separador; TS idiomático es `;` dentro de un type
  literal (ambos válidos).
* Pendiente, rehacer en su momento (no es de tipos): violaciones de pk/uk/fk como errores
  de dominio (`domainError`, constraints nombradas desde el SSOT) y reset de la base de
  test (`DROP SCHEMA public CASCADE`, `ON_ERROR_STOP=1`). Primer intento como referencia:
  commit `5fad670` en `lucas-branch`.

## Hechos ts_backend_generator (referencia rápida, no repetir)

* `insertFn` / `generateTsBackend`: un builder `INSERT` por entidad, y el módulo entero.
* `selectByPkFn`, `selectAllFn`, `updateFn`, `deleteFn`: los otros builders de DML.
  Cubierto: pk simple y compuesta (`WHERE` y numeración de placeholders `SET`-luego-`WHERE`
  en `update`), `selectAll` sin parámetros, `update` de fila completa, `update` omitido
  para entidades all-pk (`hasNonPkColumns`).
* `insertFnTest` .. `deleteFnTest` / `generateTsBackendTests`: el test #1 por builder y el
  módulo de tests entero (imports `node:test`/`node:assert` + import de `./dml.ts`).
* Tipos TS y samples de los tests generados derivados del tipo de Zig de cada dominio
  (`tsTypeOf` vía `type_defs`); dominio que no está en `type_defs` → no compila
  (`ts_type_not_in_type_defs.zig`). Reemplaza a `ts_type_defs` / `ts_sample_defs`.
* `zig build ts-backend`: genera `dml.ts` + `dml.test.ts` y corre `node --test`.

## Hechos (referencia rápida, no repetir)

* Columna simple con su tipo SQL (`createTableSql`, un campo).
* Varios campos, cada uno con el tipo SQL que le corresponde.
* Más de una entidad en un mismo esquema (`schemaSql`, entidades
  independientes, sin fk).
* Tipo SQL de cada columna derivado del tipo de Zig de su dominio
  (`sqlTypeOf` vía `type_defs`, rama `type-translation`; reemplaza a
  `aida.sql_type_defs`): `bool` → `BOOLEAN`, `[]const u8` → `TEXT`, entero
  → el entero de Postgres más chico que lo contiene, con un `DOMAIN`
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
* Pk siempre `NOT NULL`, sin importar el `nullable` del campo (fixture
  `combinacion`, pk `a`,`b`, ninguno con `nullable: false` explícito).
* Esquema completo de aida (`schemaSql` sobre las 11 entidades de
  `aida.entity_defs`, en orden de declaración, en
  `test/sql_generator_aida_test.zig`) — sostiene el "ver corriendo" de este
  hito (`zig build print-schema`).
