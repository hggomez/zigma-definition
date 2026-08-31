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

**Falta** para completar la interfaz de DML: más casos de integración (update toca solo lo
nombrado, delete→selectByPk vacío, violación de uk/fk como error de dominio, entidad de pk
compuesta), y el codec de `fecha` (hoy `insertClases` pasa el objeto `{ año, mes, día }`
crudo a una columna `TEXT` — `pg` lo stringify a `"[object Object]"`; hay que serializar).
Después: el resto del backend (endpoints HTTP) y el interop TS → Zig para las reglas de
dominio.

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
TS → Zig. **Sin decidir todavía cuál**, para la próxima sesión:

* **C ABI**: Zig exporta funciones (`export fn ... callconv(.c)`) a una lib compartida
  (`.so`/`.dll`), invocada desde Node con una librería tipo `koffi` (FFI sin escribir un
  addon nativo). Más directo, pero la lib queda atada a la plataforma/arquitectura donde
  se compiló — no es problema si el contenedor del backend siempre la compila en su
  propio build Linux.
* **WASM**: Zig compila a `wasm32`, corrido con un runtime WASM embebido en Node
  (bindings de `wasmtime`/`wasmer`). Más portable (no atado a la plataforma del
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

## Próximos pasos

1. Elegir mecanismo de interop TypeScript → Zig (C ABI vía `koffi` vs WASM) —
   investigación, no implementación todavía.
2. Definir cómo se generan los exports concretos: el paso de build que monomorfice, para
   el sistema aida, las funciones de validación/reglas de negocio escritas en Zig hacia
   el ABI/WASM elegido.
3. Armar el `backend` como servicio propio en `docker-compose.yml` (junto a `postgres`):
   Dockerfile de Node, sin acoplar el desarrollo al host Windows.
4. Elegir cliente de Postgres para TypeScript y, si hace falta, framework HTTP (o arrancar
   con Node puro).
5. Primer paso chico, TDD, a acordar con el programador: probablemente el primer llamado
   real desde TypeScript a una función de Zig ya compilada (el `validarCargo` de ejemplo),
   antes de sumarle HTTP o DB.
