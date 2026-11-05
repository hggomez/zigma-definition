# Objetivo de esta rama (`lucas-branch`)

A partir de un sistema descripto con el framework `zigma` (`src/zigma.zig`), generar y hacer
correr, de punta a punta:

1. **Base de datos**: el esquema de Postgres (tablas, pks, uks, fks) derivado de las
   `EntityInfo` del sistema.
2. **Backend**: la interfaz de DML y los endpoints CRUD sobre esa base, derivados de las
   mismas definiciones.
3. **Frontend**: las pantallas para operar esas entidades, también derivadas de las
   definiciones.

Todo sale de la única fuente de verdad: el vocabulario de `src/zigma.zig` más un sistema
concreto. El sistema de ejemplo es `examples/aida.zig`: cada paso se ve funcionando
corriendo aida (`zig build up -Dsystem=examples/aida.zig -Dseed=examples/aida_seed.sql`),
no solo pasando tests.

## Forma de trabajo

* TDD, pasos chicos: primero el test que muestra el problema, mostrar los rojos, esperar la
  revisión del programador antes de corregir.
* En cada paso relevante, correr aida de verdad (levantar la instancia, abrir el frontend)
  para ver el resultado.
* Acordar el paso siguiente con el programador antes de programarlo.

## Estado

### Base de datos (`src/sql_generator.zig`)

* `schemaSql(type_defs, entity_defs)`: el DDL del sistema como string comptime. Primero un
  `CREATE DOMAIN` por cada entero angosto que usan sus columnas, después un `CREATE TYPE` por
  cada dominio struct, después un `CREATE TABLE` por entidad, en orden de declaración.
* El tipo SQL de cada columna sale del tipo de Zig de su dominio (`zig_type_map_sql.sqlTypeOf`):
  `bool` → `BOOLEAN`, `[]const u8` → `TEXT`, un entero → el entero de Postgres más chico que
  contiene su intervalo, con un `DOMAIN` (`zig_u8`) que lo restringe al intervalo de Zig
  cuando el de Postgres es más ancho (`i64` → `BIGINT`, sin dominio).
* Un dominio struct (`fecha`) es un tipo compuesto con su nombre, y cada columna struct lleva
  un `CHECK` `<entidad>_<columna>_complete` (el struct entero o `NULL`: los atributos de un
  compuesto no pueden ser `NOT NULL`).
* Cada tabla: `NOT NULL` para `nullable: false` y para la pk, `PRIMARY KEY`, un `UNIQUE` por
  uk, un `FOREIGN KEY` por fk (renombradas, reflexivas, dos a la misma entidad).

### Backend TypeScript (`backend/`, servicio `backend`)

* **`dml.ts`** (`src/ts_backend_generator.zig`): por entidad, hasta cinco builders que
  devuelven `{ text, values }` (lo que recibe `pool.query` de `pg`): `insert<E>`,
  `select<E>ByPk`, `selectAll<E>`, `update<E>` (de fila completa; solo si la entidad tiene
  campos fuera de la pk) y `delete<E>`. El tipo TS de cada campo sale del tipo de Zig de su
  dominio (`zig_type_map_ts.tsTypeOf`). En el `WHERE` de la pk, una columna struct se compara
  con el parámetro casteado a su compuesto (`"fecha" = $3::fecha`): `pg` manda los parámetros
  sin tipo y Postgres no sabe leer el texto de un compuesto anónimo.
* **`dml.test.ts`**, generado también: por builder, un test que lo llama con un argumento
  de ejemplo tipado y chequea que devuelve `{ text, values }`.
* **`server.ts`** (`src/ts_server_generator.zig`): Node puro (`node:http`) y `pg`, una ruta
  explícita por entidad y operación, bajo `/api/<entidad>`:
  * `GET` sin query string: la lista (un array JSON pelado); `GET ?<pk completa>`: la fila, o
    404 JSON.
  * `DELETE ?<pk completa>`: 204 sin cuerpo, o 404 JSON.
  * `POST`, la fila como cuerpo JSON: 201 sin cuerpo.
  * `PUT ?<pk completa>`, los campos fuera de la pk como cuerpo: 204, o 404 JSON; de fila
    completa (un campo nullable ausente se escribe `null`). Solo para las entidades con algún
    campo fuera de la pk.
  * El query string tiene que ser exactamente la pk (un struct, un parámetro por campo:
    `fecha.año=…`) y cada valor tiene que entrar en su tipo; un cuerpo tiene solo los campos
    de la entidad, cada uno por su tipo (un nullable puede faltar). Si no, 400 JSON que nombra
    el campo.
  * Cada campo conserva su tipo del SSOT en el JSON: un `bigint` es un número JSON exacto
    (`JSON.rawJSON` sobre el texto que da `pg`; nunca pasa por un `number`), un struct es un
    objeto (`fecha` → `{ "año", "mes", "día" }`), leído del texto del compuesto. Un cuerpo se
    lee en el mismo formato (`readBody` guarda el texto exacto de cada número).
  * Respuestas siempre JSON salvo 201/204: un error es `{ "error": ... }` (404 sin ruta, 500
    ante una excepción, que se loguea).

### Frontend (`frontend/`, servicio `frontend`)

* Generado por `src/frontend_generator.zig`: HTML + JS planos, sin framework ni paso de
  build, servidos por nginx, que hace proxy de `/api/` al backend (mismo origen: sin CORS).
* Hasta tres páginas por entidad, sus URLs espejan las de la API (`/<entidad>`,
  `/<entidad>/new` y `/<entidad>/edit`), más un índice. Las páginas navegan, listan,
  muestran una fila, la borran, crean una y la modifican:
  * sin query string, la lista (`/docentes` muestra lo que da `GET /api/docentes`): una
    tabla con una columna por campo (encabezado: su label), la primera celda de cada fila es
    el link a la página de la fila, y un link `New`;
  * con el query string de una pk (`/clases?periodo=…&materia=…&orden=…`; un struct, un
    parámetro por campo), esa fila: sus campos como pares label/valor (`dl`), un link
    `Edit` (si la entidad tiene algún campo fuera de la pk) y un botón `Delete`, o
    `No row with that pk.` si no hay fila;
  * `Delete` pide confirmación en la página (`Delete this row?`, `Yes, delete` / `Cancel`,
    sin diálogo nativo); confirmado, `DELETE /api/<entidad>?<pk>` y vuelve a la lista. Ante
    cualquier respuesta que no sea 204 (por ejemplo, una fila referenciada: el 500
    genérico), `The row could not be deleted.` y la fila queda;
  * `/<entidad>/new` (un `<entidad>/new.html` generado): un formulario con un input por
    campo (texto; un entero como texto, que va como número JSON exacto; un checkbox para un
    boolean; un `fieldset` con un input por parte para un struct). `Create` hace el `POST` y
    vuelve a la lista; un campo nullable (fuera de la pk) vacío va `null` (un struct, si
    todas sus partes están vacías); ante cualquier respuesta que no sea 201,
    `The row could not be created.` y el formulario conserva lo escrito. `Cancel` vuelve a
    la lista. Un texto no nullable vacío va como `""`; un checkbox siempre es
    `true`/`false`; una fk es un input de texto;
  * `/<entidad>/edit?<pk>` (un `<entidad>/edit.html` generado solo para las entidades con
    algún campo fuera de la pk): el mismo formulario lleno con la fila, la pk visible pero
    no editable. `Save` hace el `PUT` de los campos fuera de la pk (la fila completa: un
    nullable vaciado va `null`) y vuelve a la lista; ante cualquier respuesta que no sea
    204, `The row could not be updated.` y el formulario conserva lo escrito. `Cancel`
    vuelve a la página de la fila; una pk sin fila, `No row with that pk.`
  * Cada número como su texto exacto, `null` vacío (se ve "—"), un struct como sus campos
    unidos con `-`.
* Estilo admin panel: header con el nombre del sistema (link al índice), nav lateral con
  todas las entidades (la actual marcada) y el contenido en `<main>`, con un `common.css`
  fijo.

### Reglas de dominio (`src/rules.zig`, `src/rules_wasm.zig`, `src/ts_rules_generator.zig`)

* `zigma.defineRules(type_defs, .{ .nombre = .{ .record = ..., .rule = ... } })`: una regla es
  siempre una validación, que toma exactamente `RecordInstanceType(type_defs, record)` y
  devuelve `error{...}!void`. El record va explícito porque el tipo del parámetro perdió lo
  que necesita un generador (los dominios, `nullable`); `defineRules` chequea que coincidan.
* Un `.wasm` por sistema, con un export por regla (por comptime, sin generar texto Zig) más
  `alloc`. Contrato: entrada, la instancia como JSON UTF-8 en memoria pedida con `alloc`;
  salida, un string empaquetado `ptr << 32 | len`: `""` si pasa, el nombre del error de Zig
  si la regla la rechaza, `"InvalidInput"` si el JSON no es una instancia del record.
* `rules.ts`, generado: carga `./rules.wasm` al importarse y expone cada regla tipada, con
  resultado `{ ok: true } | { ok: false; error: E }` y un serializador campo por campo (solo
  los campos del parámetro; `bigint` como número JSON exacto). Confía en los tipos TS de su
  argumento: validar datos de afuera es trabajo del que llama.
* Probado con `test/test_system.zig` (salas y reservas).

### Build e infraestructura

* `build.zig` crea una instancia: `up` / `down` / `print-schema` / `create-database` con
  `-Dsystem=<ssot>` y, opcional, `-Dseed=<sql>`. No nombra ningún sistema.
* `src/generate.zig` escribe lo generado para el sistema que recibe como `"system"`
  (`schema`, `dml`, `dml-tests`, `server`, `frontend DIR`, `rules-ts`, `env`), a stdout o a
  un directorio; el build lo copia a `backend/src/`, `frontend/public/` y `.env`
  (gitignoreados).
* Los nombres de la infraestructura salen del sistema: `.env` tiene `SYSTEM_NAME=<name>` y
  los compose lo interpolan (contenedor, usuario y base de Postgres, volumen, proyecto de la
  instancia `zigma-<name>`). `psql` corre dentro del servicio `postgres` con el usuario y la
  base del contenedor.
* Dos stacks que no chocan: el de los tests (`docker-compose.yml` solo: 8080 / 3000 / 5432)
  y el de la instancia (`docker-compose.instance.yml` encima: 8081 / 3001 / 5433).
* Los tests son un paquete propio, `test/build.zig`, que reusa las `pub fn` de `build.zig`;
  ver `CLAUDE.md` para los pasos.

## Decisiones

* **El DDL es un string generado en comptime**, no una conexión: los tests son asserts sobre
  el texto, y el framework no queda atado a ningún driver.
* **Postgres vía Docker, sin driver para Zig**: `psql` corre dentro del contenedor, así que
  la única dependencia del host para la base es Docker.
* **El backend se genera en TypeScript (Node), no en Zig**: portabilidad (sin atar el
  desarrollo a un toolchain nativo por sistema operativo) y el ecosistema maduro de Node para
  HTTP y Postgres. Corre en su propio contenedor; el código generado se escribe en el host,
  así que no hay Zig en la imagen.
* **Cliente de Postgres: `pg`**: el código generado está armado sobre su API (`{ text, values }`
  para `pool.query`). `pg` devuelve un `BIGINT` como string y un compuesto como su texto
  (`"(2026,3,14)"`); `server.ts` hace la traducción a JSON.
* **Las reglas de Zig se corren desde TS compiladas a WASM** (el `WebAssembly` que Node ya
  trae), no por una lib nativa con C ABI: el `.wasm` no queda atado a la plataforma donde se
  compiló. Como las funciones de `zigma` son genéricas, el build monomorfiza un export por
  regla de cada sistema.
* **HTTP con Node puro, sin framework**: las rutas no se escriben a mano, se generan desde
  `entity_defs` (una por entidad y operación); un framework de rutas resuelve el caso que no
  tenemos.
* **API**: la pk va en el query string; todas las respuestas son JSON salvo los 201/204 sin
  cuerpo.
* **Frontend plano** (HTML + JS sin framework ni build), servido por nginx; **e2e con
  Playwright en un contenedor** (servicio `e2e`, imagen `mcr.microsoft.com/playwright` a la
  misma versión que `@playwright/test`).
* **El sistema se pasa por línea de comandos** y los nombres de la infraestructura salen de
  su `name`: fuera de su SSOT, su seed y los tests, ningún archivo nombra a un sistema.

## Pendiente

* **Frontend**, tareas futuras (cada una a acordar antes de programarla):
  1. **Un query string que no es una pk** en la página de una fila o en la de edición (el
     400 de la API: un parámetro de más, uno repetido, uno de la pk que falta, un valor
     fuera de su tipo): qué muestra la página. Hoy no está definido.
  2. **Errores que nombran el campo** en los formularios de alta y modificación: hoy el
     mensaje es genérico (`The row could not be created.` / `updated.`); la API ya nombra el
     campo en su 400 (`field 'fecha.mes' must be an integer in 0..255`).
  3. **Una fk como lista de los valores posibles** (las filas de la entidad destino), no un
     input de texto libre.
  4. **Una visualización propia para fechas**, ligada a un tipo fecha del framework sobre
     `DATE` (hoy un struct `fecha` se ve como sus campos unidos con `-`, y se carga parte por
     parte).
* **Errores de dominio de pk/uk/fk**: hoy una violación (pk duplicada, fila referenciada) es
  el 500 genérico; mapearlas a errores de dominio con constraints nombradas desde el SSOT.
  Referencia de un intento: commit `5fad670` en `lucas-branch-first-attempt`.
* **Reglas**: cuándo se aplica una regla (ver `PREGUNTAS.md`); declarar las de aida
  (`validarCargo` es una función suelta y `cargo` no tiene entidad) y llevar su `.wasm` y
  `rules.ts` al backend.
* **`nullable` en los tipos**: `RecordInstanceType` y los tipos de `dml.ts` no lo reflejan (un
  campo nullable es `T`, no `?T` / `T | null`); ver `TEST_QUEUE.md`.
* **Texto dentro de un compuesto** y **un struct dentro de un struct**: no compilan.
* **Fks cíclicas entre entidades distintas**: el DDL las emite en línea, en orden de
  declaración, y Postgres exige que la tabla referenciada exista (haría falta `ALTER TABLE
  ... ADD CONSTRAINT` al final).
