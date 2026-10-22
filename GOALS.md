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
conexión viva) y no acopla el framework a ningún driver. Al principio apuntaba a SQLite y
el "ver corriendo" era solo imprimir el DDL; el destino terminó siendo **Postgres vía
Docker** (ver "Hito 1 completo" más abajo). Los puntos que siguen están en orden
cronológico: los primeros describen el mapeo de tipos a mano, reemplazado después en la
rama `type-translation` (último punto).

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
  * **Reemplazado** en la rama `type-translation`: las firmas son ahora
    `createTableSql(type_defs, name, entity)` y `schemaSql(type_defs, entity_defs)`,
    `aida.sql_type_defs` y `sql_unknown_type_mapping.zig` ya no existen, y `fecha` es un
    tipo compuesto (ver el último punto).
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
* Rama `type-translation`: el tipo SQL de cada columna sale del tipo de Zig de su dominio
  (el generador recibe el `type_defs` del sistema y pasa por `zig_type_map_sql.sqlTypeOf`),
  reemplaza a la tabla a mano `aida.sql_type_defs`. Un entero más angosto que su entero de
  Postgres va con un `DOMAIN` (`zig_u8`) que lo restringe al intervalo de Zig; `integer`
  (`i64`) es `BIGINT`. Un dominio respaldado por un struct (`fecha`) es un tipo compuesto
  con el nombre del dominio (`CREATE TYPE fecha AS (año zig_u16, mes zig_u8, día zig_u8)`),
  y cada columna struct lleva un `CHECK` `<entidad>_<columna>_complete` (el struct entero o
  `NULL`: los atributos de un compuesto no pueden ser `NOT NULL`). Un struct dentro de un
  struct todavía no compila (el interno no tiene dominio ni nombre). Aplicado a mano contra
  Postgres: el esquema entra entero, y una `fecha` incompleta, `mes = 300` o `año = -1` se
  rechazan. Falta el lado TS ↔ Postgres (cómo `dml.ts` manda y lee un `fecha`).
  * El "no compila" de un dominio que no está en `type_defs` es ahora
    `sql_type_not_in_type_defs.zig` (`"type 'fecha' is not in type_defs"`). El test del
    esquema completo de aida vive en `test/sql_generator_aida_test.zig`.
  * Confirmado de punta a punta (2026-10-22) con `docker compose down -v` seguido de
    `zig build ts-backend-db`: sobre una base vacía el esquema entra sin errores
    (2 `CREATE DOMAIN`, 1 `CREATE TYPE`, 11 `CREATE TABLE`) y el test de integración pasa.

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
  * El tipo TS de cada campo sale del tipo de Zig de su dominio: el generador recibe el
    `type_defs` del sistema y pasa por `zig_type_map_ts.tsTypeOf` (rama `type-translation`,
    reemplaza a las tablas a mano `ts_type_defs` / `ts_sample_defs` que tenía aida).
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
* **El backend en su propio contenedor** (2026-10-22): servicio `backend` en
  `docker-compose.yml`, junto a `postgres`. `backend/Dockerfile` es `FROM node:22.19.0-alpine`
  (fijado) + `npm ci` con el `package-lock.json` versionado + copia de `src/`: el código
  generado (`dml.ts`) lo escribe `zig build` en el host, **no hay Zig en la imagen** (sin
  riesgo de que desaparezca de las descargas la versión dev fijada). El servicio no tiene
  proceso de larga duración (todavía no hay capa HTTP): el código del backend corre a
  demanda con `docker compose run --rm backend node ...`, y llega a Postgres por el nombre
  del servicio (`DATABASE_URL=postgres://aida:aida@postgres:5432/aida`, `depends_on`
  postgres sano). Por eso el `docker compose up -d --wait` del build levanta solo
  `postgres` (el `backend` terminaría enseguida y `--wait` lo tomaría como falla).
  * Test: `zig build backend-docker` regenera `dml.ts`, aplica el esquema, construye la
    imagen y corre `test/backend_docker_test.zig`, un test de Zig que ejecuta dentro del
    contenedor insert → selectByPk → delete de `periodos` y chequea que `DATABASE_URL`
    nombre al servicio `postgres` (no `localhost`): en el host solo corre Docker. Fuera de
    `zig build test` (necesita Docker).
  * La primera corrida tardó más de 10 minutos (probablemente la descarga de la imagen de
    Node y el primer build; no se confirmó); las siguientes, segundos.

**Falta** para completar la interfaz de DML: más casos de integración (update toca solo lo
nombrado, delete→selectByPk vacío, violación de uk/fk como error de dominio, entidad de pk
compuesta), y la traducción de valores TS ↔ Postgres: hoy `insertClases` pasa el objeto
`{ año, mes, día }` crudo a la columna de tipo compuesto `fecha` (`pg` lo stringify a
`"[object Object]"`; hay que serializarlo al literal del compuesto y parsearlo al leer), y
los campos `bigint` (`i64`) y los enteros con `DOMAIN` todavía no pasan por ningún test de
integración (el único hoy es `periodos`, una sola columna de texto).
Después: el resto del backend (endpoints HTTP). El interop TS → Zig para las reglas de
dominio ya está hecho (ver "Reglas de dominio: interop TS → Zig (WASM)" más abajo).

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
TS → Zig. **Decidido: WASM** (ver "Reglas de dominio: interop TS → Zig (WASM)" más
abajo). Las opciones que se evaluaron:

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

**Decisión (2026-10-22): el cliente de Postgres del backend TS es `pg`** (node-postgres).
Ya estaba en `backend/package.json` para el test de integración, y el código generado está
armado alrededor de su API: cada builder de `dml.ts` devuelve `{ text, values }`, que es lo
que recibe `pool.query(text, values)`. Consecuencias a tener en cuenta en la traducción de
valores TS ↔ Postgres: `pg` devuelve `BIGINT` como string por defecto (no `bigint`) y un
tipo compuesto como su forma de texto (`"(2026,3,14)"`); las conversiones se registran por
tipo. Se descartó cambiar a otro cliente (`postgres.js`, con otra API: templates
`` sql`...` `` en vez de `{ text, values }`), que obligaría a cambiar lo que genera el
generador.

**Ya no aplica** (era para un backend en Zig, descartado por la decisión de arriba):

* La investigación de `libpq` (driver de Postgres para Zig) — el cliente de Postgres pasa
  a ser responsabilidad de TypeScript (decidido: `pg`, ver arriba).
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

## Reglas de dominio: interop TS → Zig (WASM)

Las reglas de dominio se escriben una vez en Zig y el backend TS las corre compiladas a
WASM. Hecho en la rama `type-translation`, probado con un sistema propio de prueba
(`test/test_system.zig`: salas y reservas, sin aida, que no se tocó).

**Declaración (`zigma.defineRules`, `src/rules.zig`).** Las reglas de un sistema se
declaran con `zigma.defineRules(type_defs, .{ .checkBooking = .{ .record = booking, .rule
= checkBooking } })`: la key es el nombre de la regla. Una regla es **siempre una
validación**: toma exactamente `RecordInstanceType(type_defs, record)` y devuelve
`error{...}!void`. El record va explícito porque el tipo del parámetro (el struct
derivado) perdió lo que necesita un generador (los tipos de dominio, `nullable`, de qué
record viene); `defineRules` chequea que los dos coincidan. Rechazos: 10 casos "no
compila" (`test/compile_errors/rules_*`).

**El módulo WASM (`src/rules_wasm.zig`).** Genérico: exporta las reglas del módulo que
`build.zig` le da como `"system"`, con `@export` en un loop comptime (sin generar texto
Zig). **Un `.wasm` por sistema**, con un export por regla, con el nombre de la regla, más
`alloc`. Contrato con el que llama:
* entrada: la instancia del record como JSON UTF-8, escrita en memoria pedida con `alloc`;
  el export recibe puntero y largo, y la libera;
* salida: un string empaquetado `ptr << 32 | len`: `""` si pasa, el nombre del error de Zig
  si la regla la rechaza, `"InvalidInput"` si el JSON no es una instancia del record
  (`std.json` parsea al tipo exacto: campo faltante o de más, tipo incorrecto, fuera de
  rango, `null` → `"InvalidInput"`). Los strings de resultado son constantes: no se liberan.
* Hallazgos: `alloc(0)` daba la dirección `0xFFFFFFFF`, que no es memoria, así que una
  entrada vacía rompía del lado que llama; ahora devuelve un byte estático y el export
  libera solo entradas no vacías. `rdynamic` (que conserva los exports) también exporta
  `__stack_pointer`: se acepta como artefacto del build, porque la lista exacta
  (`export_symbol_names`) obligaría a repetir los nombres de las reglas en `build.zig`.

**`rules.ts`, generado (`src/ts_rules_generator.zig`).** La mitad TS del contrato. Carga
`./rules.wasm` (al lado suyo) una vez, al importarse, y expone cada regla tipada:
* parámetro: el tipo TS del parámetro de la regla (`tsTypeOf`), el mismo tipo que parsea
  WASM;
* resultado: `RuleResult<E> = { ok: true } | { ok: false; error: E }`, con `E` los nombres de
  error de Zig (ordenados: el orden que da el compilador no es estable) más
  `"InvalidInput"`;
* serializador campo por campo: solo los campos del parámetro van al JSON (TS deja pasar
  objetos con propiedades de más, como una fila entera, que WASM rechazaría), y un `bigint`
  como número JSON exacto (`JSON.rawJSON`; `JSON.stringify` tira con un `bigint`).
* `rules.ts` **confía en los tipos TS** de su argumento: datos sin tipar en runtime (un
  `bigint` faltante o con un string) pueden hacer tirar al serializador antes de llegar a
  WASM. Validar datos de afuera es trabajo del que llama.

**Tests.** Nativos en `zig build test` (`run` del módulo WASM con el testing allocator, y el
texto exacto de `rules.ts`); contra el `.wasm` real desde Node en `zig build rules-wasm`
(necesita Node, fuera de `zig build test`): el contrato escrito a mano
(`test/rules_wasm_node_test.zig`: exports, `alloc`, empaquetado, rango de `i64`, 10.000
llamadas sin crecer la memoria) y el `rules.ts` generado al lado del `.wasm`
(`test/rules_ts_node_test.zig`: `RuleResult`, propiedades de más, `bigint` exacto incluido
2^53 + 1).

**Falta:** cuándo se aplica una regla (qué la dispara: tarea para más adelante); declarar
las reglas de aida (`validarCargo` es todavía una función suelta, y `cargo` no tiene
entidad); el `.wasm` y `rules.ts` de aida en el backend.

## Próximos pasos

Hecho: el `backend` como servicio propio en `docker-compose.yml` (ver el progreso del
hito 2) y el cliente de Postgres (`pg`, ver "Decisiones previas").

1. Elegir framework HTTP, si hace falta (o arrancar con Node puro), y la capa HTTP: con ella
   el servicio `backend` pasa a tener un proceso de larga duración.
2. Reglas: definir cuándo se aplica una regla y llevar las de aida (`validarCargo`) al
   backend con `rules.ts` / `rules.wasm` (en la imagen, generados en el host como `dml.ts`).
3. Traducción de valores TS ↔ Postgres (`fecha`, `bigint`), ver "Falta" en el hito 2.
