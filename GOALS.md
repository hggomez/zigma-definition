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
* **Hito 1 completo**: el DDL corre contra un Postgres real, no solo se imprime.
  Decisión: **Postgres vía Docker**, sin driver de Postgres para Zig — `psql` corre
  *dentro* del contenedor, así que la única dependencia del host es Docker. El patrón
  se tomó (no se heredó el código) de `origin/example-database-connection`, una rama
  exploratoria no mergeada que ya lo había resuelto así.
  * `docker-compose.yml`: un servicio `postgres:16` (`zigma_aida_postgres`, db/user/pass
    `aida`), con `healthcheck` (`pg_isready`) para que el arranque sea determinístico.
  * `build.zig`, step `zig build create-database`: corre `docker compose up -d --wait`
    (bloquea hasta que el healthcheck pasa — sin esto, `docker exec` podía llegar antes
    de que Postgres estuviera listo para aceptar conexiones), captura el stdout de
    `print_schema` (`captureStdOut`) y lo pipea a
    `docker exec -i zigma_aida_postgres psql -U aida -d aida` (`setStdIn`).
  * Bug encontrado y corregido en el camino: `examples/print_schema.zig` usaba
    `std.debug.print`, que en Zig **siempre** escribe a stderr, nunca a stdout —
    `captureStdOut` capturaba un string vacío. Al principio pasó desapercibido porque
    una corrida vieja había dejado cacheado un resultado previo; se detectó por un
    `failed command` espurio en la salida de `zig build`, se confirmó pidiendo
    `\dt`/`\d` directo a Postgres (las tablas no coincidían con lo esperado hasta
    corregirlo). Se reescribió con la interfaz nueva de Zig 0.17
    (`std.process.Init.io`, `std.Io.File.stdout().writer(io, &buffer)`,
    `stdout.print(...)` + `stdout.flush()`), que sí escribe a stdout.
  * Confirmado de punta a punta con `docker compose down -v` (reset completo) seguido
    de `zig build create-database`: las 11 tablas se crean limpias, con sus fks, pks
    compuestas y `NOT NULL` correctos (verificado con `psql -c "\dt"` y `\d docentes`).

## Hito 2 (backend): estado y decisiones

En arranque, nada implementado todavía (ningún código de este hito escrito). Lo que se
acordó hasta ahora, para retomar directamente en la próxima sesión:

* **HTTP: `std.http.Server` directo, sin framework.** Decisión tomada. Investigado
  (`std/http/Server.zig` de nuestro toolchain pineado, no de blogs de otras versiones):
  es deliberadamente bajo nivel — `http.Server.init(in: *Reader, out: *Writer)` sobre
  una conexión de `std.net.Server.accept()`, `server.receiveHead()` devuelve un
  `Request` con `.head.method` / `.head.target` (path crudo), y `request.respond(body,
  options)` para contestar. **No** trae router, ni path params, ni parseo de JSON —
  eso lo escribimos nosotros. Motivo de la decisión: el "router" que necesitamos no es
  un DSL de rutas a mano (`router.get("/alumnos/:id", ...)` estilo `http.zig`/`httpz`
  de karlseguin) sino un dispatch genérico derivado de `entity_defs` (nombre de
  entidad + verbo CRUD → handler), en línea con cómo ya se derivó `sql_generator` de
  `EntityInfo`. Un framework de rutas está pensado para el caso que NO tenemos (rutas
  escritas a mano una por una).
* **Driver de Postgres: todavía sin decidir, sin probar contra nuestro toolchain.**
  Investigado (no implementado): dos forks reales de `pg.zig`, cliente nativo del
  protocolo de Postgres (sin libpq).
  * `karlseguin/pg.zig` (el original): apunta a Zig 0.16.0 en `master`. Pool
    (`pg.Pool`), queries parametrizadas (`pool.query("... where power > $1", .{9000})`),
    filas tipadas (`row.get(i32, 0)`) y mapeo a struct por nombre de columna
    (`row.to()`). TLS marcado experimental, necesita OpenSSL. Es estricto: no hace
    coerción de tipos.
  * `lalinsky/pg.zig` (fork activo, commits recientes): reescrito para la interfaz
    `std.Io` nueva de Zig — la misma que usamos recién para arreglar el bug de stdout
    en `print_schema.zig` (`std.Io.Threaded` / `init.io`). Reemplaza OpenSSL por
    `tls.zig` para que TLS funcione bajo `std.Io`. Misma forma de pool/query/row que
    el original, más `error.Timeout` en `acquire()`.
  * Ninguno de los dos fija `minimum_zig_version` en su `build.zig.zon`: sin garantía
    de que compilen contra nuestro pin exacto (`0.17.0-dev.1778+767d25269`) — hay que
    probarlo cuando se llegue a este paso, no asumirlo de la documentación.
  * Candidato preferido, a confirmar probando: **`lalinsky/pg.zig`**, por estar
    construido sobre la misma interfaz `std.Io` que ya estamos usando (en vez de la
    original, pensada para el modelo bloqueante viejo).
  * Alternativa de respaldo si ninguno compila: bindings C a `libpq` vía
    `@cImport`/`translate-c` (más trabajo de wireo, pero `libpq` es estable y no
    depende de que un paquete Zig siga el ritmo de los dev builds).

## Próximos pasos

1. Primer paso chico, TDD: decidir con qué arrancar — probablemente un handler mínimo
   de `std.http.Server` que conteste algo fijo (sin Postgres todavía), para validar el
   wireo del servidor (accept loop, `zig build run` o similar) antes de meter el
   driver. Acordar el paso exacto antes de programarlo (no se escribió código de
   hito 2 todavía).
2. Ahí sí: probar compilar `lalinsky/pg.zig` (o el original, o libpq como respaldo)
   contra nuestro `0.17.0-dev.1778+767d25269` real, no contra lo que dicen los docs.
3. Forma de los endpoints (REST por entidad vs. genérico parametrizado por
   `EntityInfo`) y forma del dispatch (`entity_defs` → tabla de handlers): a definir
   una vez que el server básico y el driver estén probados por separado.
