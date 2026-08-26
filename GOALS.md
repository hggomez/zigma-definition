# Objetivo de esta rama (`lucas-branch`)

A partir de una definición de sistema hecha con el framework `zigma` (`src/zigma.zig`),
generar y hacer correr, de punta a punta:

1. **Base de datos**: esquema (tablas, pks, uks, fks) derivado de las `EntityInfo` del
   sistema.
2. **Backend**: endpoints CRUD sobre esa base de datos, derivados de las mismas
   definiciones.
3. **Frontend**: pantallas para operar esas entidades, también derivadas de las
   definiciones.

Todo generado (o servido on-the-fly) a partir de la única fuente de verdad: las
definiciones en `src/zigma.zig` más un sistema concreto. El sistema de prueba es
`examples/aida.zig`: cada paso debe poder verse funcionando corriendo aida, no solo pasar
tests.

## Forma de trabajo (heredada de CLAUDE.md, aplicada acá)

* TDD, pasos chicos: primero el test que muestra el problema, mostrar los rojos, esperar
  la revisión del programador antes de corregir.
* Además de tests, en cada hito relevante correr aida de verdad (levantar el server /
  abrir el frontend / lo que corresponda a ese paso) para ver el resultado.
* Acordar el paso siguiente con el programador antes de programarlo.

## Nota: trabajo previo relacionado

`origin/frontend` (no mergeada a `main`) ya tiene una implementación exploratoria en esta
misma dirección: `src/http/main.zig` (backend HTTP), `src/json.zig` (capa JSON),
`src/frontend/` (HTML/JS que postea una entidad), más un reordenamiento de
`examples/aida.zig` en `examples/aida/`. Decisión: **no partimos de esa rama ni la
mergeamos**; arrancamos de `main` con nuestro propio enfoque TDD. Si en algún punto
conviene revisar cómo resolvió algo esa rama (parseo de celdas por tipo, alta/baja por pk
completa, etc.), se consulta puntualmente, no se hereda el código.

## Progreso

Hito 1 (base de datos) en curso. Se eligió generar el esquema como DDL en comptime
(strings), apuntando a SQLite, porque encaja con TDD (los tests son asserts sobre el
string generado, sin conexión viva) y no acopla el framework a ningún driver todavía.
El "ver corriendo" de este hito, por ahora, es imprimir el DDL generado para `aida` (no
ejecutarlo todavía contra un SQLite real — eso queda para cuando haya que elegir un
driver, ver `TEST_QUEUE.md`).

* `build.zig.zon`: `minimum_zig_version` actualizado a `0.17.0-dev.1778+767d25269` (la
  build que estaba cacheada localmente; el pin anterior, `0.17.0-dev.1282+c0f9b51d8`, ya
  no está disponible para descargar). `zig build test` funciona en esta máquina.
* Nuevo módulo `sql_generator` (`src/sql_generator.zig`, wireado en `build.zig`, tests en
  `test/sql_generator_test.zig`): genera `CREATE TABLE` a partir de `EntityInfo`.
  * `createTableSql(sql_types, name, entity_info)`: columnas con su tipo SQL (mapeo
    `sql_types` aportado por el sistema, igual que `type_defs`), `NOT NULL` para
    `nullable: false`, `PRIMARY KEY`, `UNIQUE` por cada uk, `FOREIGN KEY` por cada fk
    (incluye fks renombradas, reflexivas, dos fks a la misma entidad, y fks cíclicas
    entre dos entidades distintas).
  * `schemaSql(sql_types, entity_defs)`: un `CREATE TABLE` por entidad, en orden de
    declaración, para sistemas con más de una entidad.
  * `examples/aida.zig` tiene ahora `aida.sql_type_defs` (mapeo de sus 5 tipos de
    dominio a SQL; `fecha`, respaldado por un struct anidado, mapea igual que
    cualquier otro tipo — una sola columna opaca, `sql_generator.zig` no mira el `Type`
    de Zig subyacente).
  * Todos los tests en verde, incluido un caso "no compila"
    (`test/compile_errors/sql_unknown_type_mapping.zig`): un tipo de dominio sin
    entrada en `sql_types` da `@compileError` con mensaje propio.
* Corregido: las columnas de la pk fuerzan `NOT NULL` sin importar el `nullable` del
  campo (`isPkField` en `columnClause`, `src/sql_generator.zig`). SQL estándar lo
  implica para la pk; SQLite es la excepción y no lo fuerza salvo declaración
  explícita. Fixture `combinacion` (pk `a`,`b`, sin `nullable: false` explícito) prueba
  el caso; se actualizaron además los demás fixtures del archivo de test, que sin
  saberlo estaban documentando el comportamiento con bug.
* Test del esquema completo de aida: `schemaSql(aida.sql_type_defs, aida.entity_defs)`
  sobre las 11 entidades, un `CREATE TABLE` por entidad en orden de declaración
  (`test/sql_generator_test.zig`). Generar el DDL de las 11 juntas en una sola
  evaluación comptime superó la cuota default de branches (1000); se subió a 10000 con
  `@setEvalBranchQuota` al principio de `schemaSql`.
* "Ver corriendo" de este hito: `examples/print_schema.zig` (nuevo ejecutable, step
  `zig build print-schema` en `build.zig`) imprime a stdout el DDL completo de aida.
  Confirmado corriendo: las 11 tablas salen con sus fks (incluida la reflexiva de
  `docentes.jefe` y las dos a `docentes` desde `mesas`), pks compuestas y `NOT NULL`
  correcto.

## Próximos pasos

* **Hito 1 (base de datos), paso siguiente**: correr el DDL generado contra una base
  real. Decisión: **Postgres vía Docker** (no SQLite — la mención anterior a SQLite en
  este archivo quedó superada; el `sql_types` de `aida` sigue siendo genérico, cambiar
  de dialecto es solo cambiar ese mapeo). Falta decidir: cómo levanta Docker el build
  (`zig build` invocando `docker compose`, un step aparte, o manual por ahora),
  qué driver/binding Postgres para Zig, y si `sql_generator.zig` necesita algo
  específico de Postgres (tipos, `SERIAL`/`IDENTITY`, etc. — hoy es agnóstico).
* **Hito 2 (backend), después de la base real**: endpoints CRUD (alta/baja/modif/
  consulta = DML) derivados de las `EntityInfo`, para que el backend los use. Todavía
  sin decidir framework HTTP ni forma del endpoint (REST por entidad, uno genérico
  parametrizado, etc.) — se acuerda cuando se llegue a ese punto.
