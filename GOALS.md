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

Hito 1 (base de datos) completo. Se eligió generar el esquema como DDL en comptime
(strings), porque encaja con TDD (los tests son asserts sobre el string generado, sin
conexión viva) y no acopla el framework a ningún driver. Al principio se apuntó a
SQLite y el "ver corriendo" era solo imprimir el DDL; después se eligió **Postgres vía
Docker** y el DDL se aplica de verdad (ver el último punto de esta lista). Lo que sigue
es el registro cronológico.

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

### Progreso

Primera capa del backend TS: la **interfaz de DML sobre la base**, generada desde el SSOT
igual que el DDL (`sql_generator.zig` → DDL; ahora `ts_backend_generator.zig` → TS).

* Nuevo módulo `ts_backend_generator` (`src/ts_backend_generator.zig`, wireado en
  `build.zig`, tests en `test/ts_backend_generator_test.zig`): de cada `EntityInfo` genera
  hasta cinco *builders* parametrizados, cada uno devuelve `{ text, values }` (la forma que
  toma una query de `pg`): `insert<E>`, `select<E>ByPk`, `selectAll<E>`, `update<E>` (solo
  si la entidad tiene columnas fuera de la pk — si no, no hay nada que `SET`), `delete<E>`.
  * pk compuesta → `WHERE "a" = $1 AND "b" = $2`; en `update`, los placeholders del `WHERE`
    siguen después de los del `SET`.
  * `update` es de fila completa (todas las columnas no-pk en el `SET`), no un patch
    parcial: así sigue siendo un template estático como los demás. El patch parcial, si se
    quiere, es otro builder aparte más adelante.
  * `examples/aida.zig` tiene ahora `ts_type_defs` (dominio → tipo TS; `fecha` es el struct
    inline `{ año; mes; día }`) y `ts_sample_defs` (dominio → literal de ejemplo para los
    tests generados), ambos paralelos a `sql_type_defs`.
* El generador **también genera los tests TS** (`generateTsBackendTests`): por cada builder,
  el test #1 (arma un argumento de ejemplo tipado, llama al builder, chequea que no tira y
  devuelve `{ text, values }`). Correrlos en Node es lo que prueba que el TS emitido
  parsea, tipa y ejecuta — la capa que un string-assert de Zig no alcanza.
* `build.zig`, step `zig build ts-backend`: genera `dml.ts` + `dml.test.ts` del sistema
  aida en `zig-out/ts-backend/` y corre los tests con `node --test`. Node 22.18+ corre
  `.ts` directo y los tests solo usan `node:test` / `node:assert`, así que no hay paso de
  npm. Confirmado de punta a punta: 52 builders (11 entidades), 52 tests en verde.
* `zig build test` sigue sin depender de Node (45/45): los casos de string-assert del
  generador viven ahí; `ts-backend` es un step aparte.
* **Primer test de integración contra Postgres real, en verde**: `backend/` es ahora un
  paquete Node versionado (hand-written: `package.json` con `pg`; `dml.ts` / `dml.test.ts`
  se generan adentro y están gitignoreados). El test de integración es un **test de Zig**,
  `test/db_backend_integration_test.zig`, al lado de los otros: corre `node
  --input-type=module -e` con un script que importa los builders generados y `pg`, hace
  `insertPeriodos` → `selectPeriodosByPk` ida y vuelta por la base y limpia con
  `deletePeriodos`; el test de Zig chequea el exit code y que imprima `ROUNDTRIP_OK`.
  `zig build ts-backend-db` lo cuelga después de: levantar el contenedor, aplicar el
  esquema (mismos steps que `create-database`), `npm install`, regenerar `dml.ts`. No está
  en `zig build test` (necesita Docker + Node). Los builders todavía devuelven
  `{ text, values }` y el script los corre con `pool.query(text, values)` directo; no hay
  capa de ejecución todavía (aparece cuando un segundo test la necesite).

* **Tipos compuestos (`fecha`), hecho** (ver la decisión abajo): `schemaSql` emite un
  `CREATE TYPE` por dominio respaldado por un struct antes de las tablas, y los builders
  llevan el codec en el texto SQL (`ROW(...)::fecha` / `to_jsonb`). El test de integración
  de ida y vuelta de `fecha` (`clases`) pasa contra Postgres.

* **`bigint`, hecho**: `dml.ts` exporta `pgTypes(defaults)`, generado de
  `zig_type_map_ts.ts_parser_defs` (`i64` → OID 20 → `BigInt`); el pool se crea con
  `new pg.Pool({ connectionString, types: pgTypes(pg.types) })` (por pool, no global).
  Tests de integración en verde: `fecha` en la pk de `mesas` (keys en otro orden), `fecha`
  en `NULL` (insert y update), `orden` = 2^53 + 1 vuelve exacto.

* Más casos de integración en verde: `update` toca solo la fila de su pk, `delete` →
  `selectByPk` vacío, entidad de pk compuesta (`inscripciones`). Los scripts nuevos crean
  el pool con `pgTypes`.

* **Violaciones de pk/uk/fk como errores de dominio, hecho.** El DDL nombra cada
  constraint desde el SSOT (`<entidad>_pk`, `<entidad>_uk_<uk>`, `<entidad>_fk_<fk>`;
  funciones `pkConstraintName` / `ukConstraintName` / `fkConstraintName` de
  `sql_generator.zig`). `dml.ts` exporta `domainError(err)` (`domainErrorFn` de
  `ts_backend_generator.zig`, que usa esas mismas funciones): mapea el error de `pg`
  (`code` 23505/23503 + `constraint`) a `{ kind: 'pk_violation' | 'uk_violation' |
  'fk_violation', entity, key }` con los nombres de la definición, o `null` si no es una
  violación de clave. El borrado de una fila todavía referenciada se reporta del lado que
  referencia (`{ fk_violation, entity: 'cursos', key: 'periodos' }`).
* **La base de los tests siempre tiene el esquema actual.** `ts-backend-db` hace
  `DROP SCHEMA public CASCADE; CREATE SCHEMA public;` y aplica el DDL de cero (borra los
  datos: es una base de test). `psql` corre con `ON_ERROR_STOP=1`, así que
  `create-database` (no destructivo) falla si el esquema ya existe, en vez de pasar en
  silencio sobre un esquema viejo como antes.

La interfaz de DML queda completa. Sigue: HTTP y el llamado a reglas de dominio en Zig. Después: el resto del backend (endpoints HTTP) y el interop TS → Zig para las
reglas de dominio.

### Decisión: tipos de dominio compuestos (structs) en Postgres y en TS

**El bug que la motivó.** `fecha` es un struct en Zig (`Fecha { año, mes, día }`), un
objeto en TS (`ts_type_defs`) y una columna `TEXT` en Postgres (`sql_type_defs`), sin
nada que convierta entre las tres. Los builders pasan el objeto crudo como parámetro; `pg`
lo manda como JSON, la columna guarda `'{"año":2026,"mes":3,"día":14}'` y el `SELECT`
devuelve ese string, no el objeto. Peor en `mesas`, donde `fecha` es parte de la pk: el
`WHERE "fecha" = $n` compara contra un `JSON.stringify` que depende del orden de las keys
del objeto, así que la misma fecha con las keys en otro orden no encuentra la fila. Test
rojo que lo muestra: `test/db_backend_integration_test.zig`, "a fecha column round-trips
as { año, mes, día }".

**Decisión: generalizar a cualquier tipo de dominio respaldado por un struct, con el
codec en SQL (opción "B").**

* En la base, cada struct es un **tipo compuesto** de Postgres, derivado por reflexión
  del struct de Zig y emitido antes de las tablas:
  `CREATE TYPE "fecha" AS ("año" INTEGER, "mes" SMALLINT, "día" SMALLINT)`. La columna es
  de ese tipo, no `TEXT`. Esto cambia una decisión del hito 1: `sql_generator.zig` deja de
  ignorar el `Type` de Zig subyacente cuando es un struct.
* El codec vive en **el texto SQL de cada builder**; el TS generado no tiene lógica de
  conversión por tipo:
  * *Encode* (backend → base): un parámetro por campo hoja y el valor armado en SQL,
    `ROW($4::integer, $5::smallint, $6::smallint)::"fecha"` (casts explícitos para que
    Postgres infiera los tipos de los parámetros). En `values` van
    `row.fecha.año, row.fecha.mes, row.fecha.día`. Mismo encode en los `WHERE` de pk
    (`mesas`): ya no depende del orden de las keys. Si la columna es nullable:
    `CASE WHEN $4::integer IS NULL THEN NULL ELSE ROW(...)::"fecha" END`
    (`ROW(NULL, NULL, NULL)` no es lo mismo que `NULL`).
  * *Decode* (base → backend): `to_jsonb("fecha") AS "fecha"` en los `SELECT`; `pg` ya
    convierte `jsonb` en objeto JS. Por eso los `SELECT *` pasan a listar las columnas.
  * Consecuencia: un placeholder por campo hoja, no por columna (ajusta el invariante
    "un `$n` por columna" de `TEST_QUEUE.md`).
* Descartadas: codec en TS (parsear el formato texto de records de Postgres `'(…)'`, con
  quoting/escaping/NULL/anidados, y registrar un parser por OID, que es distinto en cada
  base: lo más frágil) y mixto (se queda con la parte difícil de la opción TS). Variante
  considerada para el encode: un solo parámetro JSON con
  `jsonb_populate_record(NULL::"fecha", $4::jsonb)` (SQL más corto, match por nombre, pero
  el input inválido falla recién dentro de Postgres y el NULL hay que verificarlo).
* **Tipo de cada campo del struct: decidido.** Los campos de `Fecha` son tipos de Zig
  (`u16`, `u8`), no tipos de dominio. El framework provee un mapeo de primitivos de Zig a
  su tipo Postgres y su tipo TS (`u8`→`SMALLINT`/`number`, `u16`→`INTEGER`/`number`
  porque no entra en `SMALLINT`, etc.), que consultan los generadores. Se descartó exigir
  que los campos de un struct sean a su vez tipos de dominio.

**Decisión a futuro: un `fecha` propio del framework sobre `DATE`.** Más adelante `zigma`
va a ofrecer su propio tipo fecha (en `common_type_defs` o similar) que en Postgres use el
tipo nativo `DATE` (validación, orden, funciones de fecha), en vez del compuesto genérico.
El mecanismo de arriba ya lo admite: el codec de un tipo es un par de expresiones SQL con
la misma interfaz (parámetros por campo → columna; columna → JSON), y el compuesto es solo
el default derivado del struct. Un tipo puede declarar su propio par:

| tipo | encode | decode |
|---|---|---|
| struct cualquiera (default) | `ROW($a, $m, $d)::"fecha"` | `to_jsonb("fecha")` |
| `fecha` del framework → `DATE` | `make_date($a, $m, $d)` | `jsonb_build_object('año', extract(year from "fecha")::int, …)` |

El TS generado no cambia entre uno y otro.

Para ese `fecha` se evaluó usar la conversión por defecto de `pg` (`DATE` ↔ `Date` de JS,
sin codec propio) y se descartó: un `Date` es un instante, no una fecha de calendario, y
encode/decode usan la zona horaria del proceso Node (`new Date('2026-03-14')` en UTC-3 se
guarda como `2026-03-13`; backend en contenedor UTC vs host en -03 dan días distintos).
Lo preferido para ese tipo: `DATE` en Postgres con `pg.types.setTypeParser(1082, s => s)`,
o el par encode/decode de la tabla, de modo que TS nunca vea un `Date`.

**Dónde viven los mapeos de tipos (decidido y hecho).** Toda la información de conversión
entre lenguajes vive solo en el framework: `src/zig_type_map_sql.zig`
(`sql_type_defs`) y `src/zig_type_map_ts.zig` (`ts_type_defs`), tablas indexadas por
`@typeName` del tipo de Zig (`.u8`, `.i64`, `.@"[]const u8"`, …). Un sistema solo nombra
sus dominios en `type_defs` (`email`, `fecha`, …); ya no declara mapas SQL/TS/samples
(se borraron `sql_type_defs`, `ts_type_defs` y `ts_sample_defs` de `aida.zig`).
`sqlType(type_defs, nombre)` / `tsType(type_defs, nombre)` resuelven en orden: entrada en
la tabla del framework; dominio de `type_defs` a través de su tipo de Zig (un struct es el
compuesto con el nombre del dominio en SQL, y un objeto inline en TS); si no, error de
compilación. Un dominio con mapeo propio (el `fecha` del framework sobre `DATE`) se agrega
como entrada en esas tablas. Los generadores reciben `type_defs`; los samples de los tests
TS se derivan del tipo de Zig dentro de `ts_backend_generator` (`1n` para `bigint`, un
objeto para un struct). `i64` → `BIGINT` / `bigint` (el backend tiene que registrar
`pg.types.setTypeParser(20, BigInt)`), así que el dominio `integer` ahora es `BIGINT`.

La conversión real en el cable la sigue haciendo `pg` con sus parsers por defecto
(`INTEGER`→`number`, `BOOLEAN`→`boolean`, `TEXT`→`string`, `jsonb`→objeto; ojo,
`BIGINT`→`string` y `DATE`→`Date` en hora local).

### Decisiones previas

**Decisión de esta sesión, reemplaza lo que sigue**: el backend no se escribe en Zig. Se
genera en **TypeScript (Node)**, y corre como su propio servicio en `docker-compose.yml`
(un contenedor `backend` junto al de `postgres`, mismo patrón: la aplicación generada
corriendo como servicio, no un contenedor de desarrollo/build para compilar Zig). Motivo:
portabilidad (no atar el desarrollo a un toolchain nativo por SO) y no reinventar en Zig
lo que ya existe maduro en el ecosistema Node para HTTP/Postgres.

El backend en TypeScript necesita poder invocar funciones de dominio escritas en Zig (por
ejemplo `validarCargo`) sin reescribirlas: esas reglas viven en la única fuente de verdad
(las definiciones `zigma`/`aida` en Zig), así que hace falta un mecanismo de interop
TS → Zig. **Decidido: WASM** (ver "Interop TS → Zig" más abajo). Las opciones que se
evaluaron:

* **C ABI**: Zig exporta funciones (`export fn ... callconv(.c)`) a una lib compartida
  (`.so`/`.dll`), invocada desde Node con una librería tipo `koffi` (FFI sin escribir un
  addon nativo). Más directo, pero la lib queda atada a la plataforma/arquitectura donde
  se compiló — no es problema si el contenedor del backend siempre la compila en su
  propio build Linux.
* **WASM**: Zig compila a `wasm32`, corrido por el `WebAssembly` que Node ya trae (no
  hacen falta bindings de `wasmtime`/`wasmer`). Más portable (no atado a la plataforma del
  contenedor), pero pasar datos complejos (structs, strings) es más manual — hay que
  serializar contra la memoria lineal del módulo.
* En cualquiera de los dos casos: las funciones de `zigma` son comptime/genéricas, y no
  hay generics en un ABI C ni en WASM. Hace falta un paso de build que monomorfice
  exports concretos para el sistema específico (aida) — un export por función de
  validación/regla de negocio, no una función genérica reusable entre sistemas.

**Ya no aplica** (era para un backend en Zig, descartado por la decisión de arriba):

* La investigación de `libpq` (driver de Postgres para Zig) — el cliente de Postgres pasa
  a ser responsabilidad de TypeScript (a elegir: `pg`, `postgres.js`, etc.).
* La decisión de `std.http.Server` — el servidor HTTP pasa a ser Node/TypeScript
  (framework a elegir, o ninguno si se arranca con Node puro).

Queda documentado abajo el detalle de esa investigación (linkeo de `libpq`, forma de
`std.http.Server`, evaluación de `pg.zig`) como contexto histórico, por si en algún punto
conviene retomarlo — pero no es el plan actual.

### Contexto histórico (backend en Zig, superado)

Lo que se había acordado en la sesión anterior, cuando el plan todavía era un backend
enteramente en Zig:

* **Orden del hito, decidido**: primero backend↔DB, recién después backend↔frontend.
  Concretamente: lograr que código del backend hable con Postgres y probarlo con tests
  (TDD, sin servidor HTTP de por medio todavía) *antes* de tocar `std.http.Server`. El
  HTTP queda pospuesto — no es el próximo paso.
* **Driver de Postgres: `libpq` directo, no un paquete Zig de terceros.** Decisión
  tomada (se descarta investigar/probar `pg.zig`, tanto el original de `karlseguin`
  como el fork de `lalinsky` sobre `std.Io` — quedan documentados más abajo por si en
  algún momento conviene reconsiderarlos, pero no son el plan). `libpq` es la librería
  C oficial de Postgres: hay que ligarla desde Zig vía `@cImport`/`translate-c`. Más
  trabajo de wireo que un paquete Zig ya armado, pero sin depender de que un proyecto
  de terceros persiga el ritmo de los dev builds de Zig — motivo ya discutido al
  comparar las opciones (ver más abajo).
  * **Todavía sin investigar** (queda para la próxima sesión, antes de escribir
    código): cómo se linkea `libpq` desde `build.zig` (`linkSystemLibrary("pq")`,
    dónde vive la lib/headers en Windows — probablemente hace falta la instalación de
    PostgreSQL o solo el cliente, `libpq-dev` en Linux), forma de las funciones de la
    C API (`PQconnectdb`, `PQexecParams` para queries parametrizadas, `PQgetvalue`/
    `PQntuples`/`PQnfields` para leer resultados, `PQclear`/`PQfinish` para liberar) y
    cómo se ven esas funciones ya traducidas por `translate-c` en Zig.
* **HTTP: `std.http.Server` directo, sin framework.** Decisión tomada, pero pospuesta
  (ver arriba). Investigado (`std/http/Server.zig` de nuestro toolchain pineado, no de
  blogs de otras versiones): es deliberadamente bajo nivel —
  `http.Server.init(in: *Reader, out: *Writer)` sobre una conexión de
  `std.net.Server.accept()`, `server.receiveHead()` devuelve un `Request` con
  `.head.method` / `.head.target` (path crudo), y `request.respond(body, options)`
  para contestar. **No** trae router, ni path params, ni parseo de JSON — eso lo
  escribimos nosotros. Motivo de la decisión: el "router" que necesitamos no es un DSL
  de rutas a mano (`router.get("/alumnos/:id", ...)` estilo `http.zig`/`httpz` de
  karlseguin) sino un dispatch genérico derivado de `entity_defs` (nombre de entidad +
  verbo CRUD → handler), en línea con cómo ya se derivó `sql_generator` de
  `EntityInfo`. Un framework de rutas está pensado para el caso que NO tenemos (rutas
  escritas a mano una por una).
* **Investigado pero descartado por ahora — paquetes `pg.zig` (cliente nativo del
  protocolo de Postgres, sin libpq)**, documentado por si se reconsidera:
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
  * Ninguno de los dos fija `minimum_zig_version` en su `build.zig.zon`.

## Interop TS → Zig: WASM

**Decisión.** Las reglas de dominio de Zig se compilan a un módulo WASM que corre el
`WebAssembly` de Node. Con el sistema generado corriendo en tres contenedores Linux
(frontend, backend, postgres), la desventaja de plataforma del C ABI casi desaparece; lo
que decide es el frontend: el navegador puede cargar el **mismo** `rules.wasm` y validar
antes de mandar, con el backend como chequeo final. Una regla, escrita una vez en Zig,
en los dos lados. Un `.so` nunca corre en un navegador.

**Hecho: `validarCargo` desde Node.**
* `examples/aida_rules_wasm.zig` (escrito a mano por ahora): exporta `alloc` y
  `validarCargo`. Contrato con JS: la entrada es la instancia como JSON UTF-8 en memoria
  pedida con `alloc`; la regla la parsea con `std.json` a `aida.DefinedType(aida.cargo)`
  (el tipo sale de la definición, no se reescribe), corre la regla real, libera la
  entrada y devuelve un string empaquetado `ptr << 32 | len`: `""` si pasa, el nombre del
  error de Zig si la regla la rechaza (`"AyudanteNoPuedeDirigir"`, sale de `@errorName`,
  así que no hace falta tabla de mapeo), `"InvalidInput"` si el JSON no es una instancia
  del record (error del framework, por eso en inglés).
* `zig build rules-wasm`: compila para `wasm32-freestanding` (`ReleaseSmall`, sin entry,
  `rdynamic`), escribe `backend/src/rules.wasm` (gitignoreado) y corre
  `test/rules_wasm_test.zig` (Node, sin Docker): titular pasa, ayudante que dirige se
  rechaza, ayudante que no dirige pasa, campo faltante y campo mal tipado son
  `"InvalidInput"`.

**Cómo encaja en los contenedores (pensado, no hecho).** `rules.wasm` no depende de la
plataforma: se compila en el host con `zig build` (como `dml.ts`) y el Dockerfile del
backend es solo `FROM node` copiando lo generado, sin Zig adentro. Alternativa: Dockerfile
multi-stage con Zig, con el riesgo de que la versión dev pineada desaparezca de las
descargas (ya pasó una vez).

## Próximos pasos

1. Wrapper TS de las reglas (`rules.ts`): carga el módulo una vez y expone
   `validarCargo(cargo)` tipado, devolviendo `null` o el error de dominio. Decidir cómo
   viaja un `bigint` (`orden` es `i64`) en el JSON: `JSON.stringify` no lo serializa.
2. Generar los exports de WASM y el wrapper TS desde una lista de reglas del sistema, en
   vez de escribirlos a mano, cuando haya una segunda regla.
3. HTTP: endpoints CRUD derivados de `entity_defs` sobre los builders de `dml.ts`, con
   `domainError` → 409/422 y las reglas de Zig antes de escribir. Probablemente
   `node:http` sin framework.
4. Armar el `backend` como servicio propio en `docker-compose.yml` (junto a `postgres`).
