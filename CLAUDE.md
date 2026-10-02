# zigma-definition

Port a Zig del módulo `system-design` (TypeScript): la parte descriptiva del framework
SSOTIGAD (Single Source Of Truth Implies Good Application Design). Provee el vocabulario
para describir sistemas (tipos de dominio, entidades, campos, pks, uks, fks) de modo que
generadores automáticos puedan derivar tablas, endpoints, pantallas, serializadores y
validadores. El núcleo `zigma` (`src/core/zigma.zig`) cubre **solo la parte
descriptiva** y no importa generadores. JSON, HTTP, frontend WASM y la generación y
ejecución PostgreSQL viven en módulos independientes que consumen el contrato.

La referencia semántica es el repo `system-design` (hermano de este): la convención
Def/Info, los nombres ya elegidos y las decisiones de diseño están documentados en su
CLAUDE.md y valen acá, adaptados al lenguaje.

## Forma de trabajo

* Avanzamos de a pasos chicos, guiados por el programador. Acordar antes de programar.
* Enfoque TDD: primero el test que muestra el problema. Mostrar los rojos y **esperar la
  revisión del programador antes de corregir**.
* Los tests deben ser fuertes: además de los positivos, los rechazos se prueban como
  casos de "no compila" (ver abajo), el equivalente de los `@ts-expect-error` del repo
  TypeScript.
* Código e identificadores en inglés (los nombres de dominio del ejemplo aida quedan en
  castellano, igual que en el repo TypeScript). Este archivo y los planes, en castellano.

## Estructura

`AGENTS.md` contiene el mapa de consulta por tarea.

* `README.md`: guía de uso, arranque de AIDA, migraciones y tests.
* `DOCS.md`: referencia del contrato, arquitectura y APIs del framework.
* `docs/`: guías de build, ejecución del ejemplo, frontend, vocabulario y diseño de validadores.
* `src/core/zigma.zig`: entrada pública del descriptor y modelo normalizado (módulo
  `zigma`). Reexporta `records.zig` (dominios, campos y records), `entities.zig`
  (claves, relaciones y reglas declaradas) y `model.zig` (`Framework` y tipos derivados).
  `names.zig` contiene los helpers internos de nombres. El núcleo no conoce ningún
  sistema concreto ni importa generadores; `docs/zigma.md` explica cómo recorrerlo.
* `src/json.zig`: catálogo basado en `Model`, serialización con `std.json` y parsing
  de celdas (módulo `zigma_json`); no conoce REST ni PostgreSQL.
* `src/testing_backend/main.zig`: composición del backend de pruebas: API REST, seeds,
  repositorio en memoria y transporte compartido `zigma_std_http`.
* `src/testing_backend/memory_repository.zig`: persistencia temporal para el backend de pruebas;
  los datos se descartan al terminar el proceso.
* `src/frontend/`: cliente WASM genérico que consume el mismo contrato `system`.
* `src/rest/api.zig`: entrada pública de `zigma_rest`, rutas y coordinación CRUD.
  Reexporta los tipos compartidos de `types.zig`, los codecs de `codecs.zig` y el registro
  de validadores de `validation.zig`. Delega parsing a `request.zig` y respuestas a
  `response.zig`; estos archivos no conocen sockets ni conexiones PostgreSQL.
* `src/rest/std_http.zig`: servidor secuencial de referencia (módulo `zigma_std_http`).
* `src/postgres/ddl.zig`: generación comptime del DDL inicial (módulo
  `zigma_postgres_ddl`).
* `src/postgres/executor_ddl.zig`: ejecución transaccional independiente del driver (módulo
  `zigma_postgres_executor_ddl`).
* `src/postgres/libpq.zig`: adaptador bloqueante opcional sobre `libpq` (módulo
  `zigma_postgres_libpq`).
* `src/postgres/crud.zig`: SQL CRUD parametrizado derivado de entidades (módulo
  `zigma_postgres_crud`).
* `src/postgres/migrations/schema.zig`: entrada pública del módulo `zigma_postgres_migrations`.
  Reexporta `snapshot.zig` (modelo canónico, parsing y hashes), `diff.zig` (comparación y
  nombres) y `draft.zig` (SQL Liquibase y bloqueos). Estos archivos no conocen filesystem,
  procesos ni conexiones; los helpers estructurales compartidos viven en `snapshot.zig`.
* `src/postgres/migrations/liquibase_runner.zig`: startup versionado mediante el CLI externo (módulo
  `zigma_liquibase_runner`); credenciales solo por ambiente.
* `examples/aida/src/aida.zig`: contrato del sistema de alumnos (módulo `aida`), compartido
  por los ejemplos y usado como fixture de tests.
* `examples/aida/`: app de ejemplo que depende del paquete; `src/system.zig` expone el
  contrato y los seeds, y `build.zig` compone el backend en memoria y el frontend WASM.
* `examples/aida/src/postgres.zig`: mappings y proyección PostgreSQL compartida de AIDA.
* `examples/aida/src/rest.zig`: codecs y validadores de negocio de AIDA para REST.
* `examples/aida/src/main.zig`: entrada de la aplicación para macOS/Linux; sirve el frontend,
  espera la API después de las migraciones y cierra ambos con Ctrl+C. No requiere Python.
* `examples/aida/src/server.zig`: composición del servidor REST con libpq y migraciones Liquibase.
* `test/integration/postgres_bootstrap.zig`: auxiliar de las integraciones DDL/REST que
  usa los mappings PostgreSQL de AIDA; no tiene comando público de arranque.
* `db/`: snapshot aceptado, baseline/changesets inmutables y directorio del único draft.
* `tools/postgres_migration_tool.zig`: workflow de init/check/draft/accept-files.
* `tools/apply_migrations.zig`: aplica el historial aceptado y termina sin iniciar HTTP;
  se ejecuta mediante `zig build apply-migrations` y también desde `test-migrations`.
* `tools/postgres_schema_validator.zig`: comparación SSOT↔`pg_catalog` en un schema esperado
  temporal; se usa al aceptar migraciones y en las integraciones PostgreSQL.
* `build.zig`: opciones generales, conexiones del grafo y API pública del build.
* `build/modules.zig`: módulos publicados e imports compartidos; configuración de libpq.
* `build/app.zig`: implementación de `addApp` / `addAppFromDep`, reexportadas por la raíz.
  Componen el backend en memoria y el frontend WASM para consumidores como `examples/aida/`;
  el `build()` de la librería no instala esa app.
* `build/aida.zig`: ejecutables de AIDA, comprobación del schema y comandos de migración.
* `build/tests.zig`: suites locales, integraciones y casos esperados de no-compila.
  `docs/build.md` explica módulos, artefactos, ejecución y dependencias para leer el grafo.
* `test/*_test.zig`: pruebas de comportamiento (runtime y asserts comptime), incluidos
  el contrato de AIDA, JSON, modelo normalizado, REST y PostgreSQL.
* `test/compile_errors/*.zig`: fragmentos que **deben fallar** la compilación; `build/tests.zig`
  los compila con `expect_errors` (el paso tiene éxito solo si el error coincide) y los
  cuelga del step `test`. La lista de casos con su mensaje esperado está en `build/tests.zig`.

## Comprobaciones

* `zig build test-local`: agrega la suite `test`, el lanzador, los nombres públicos de
  comandos y las suites del consumidor `test-backend`/`test-frontend`. Requiere Node y
  Python; no requiere libpq ni servicios.
* `zig build test-json`: serialización y catálogo del modelo; incluye escaping y buffers.
* Desde `examples/aida/`, `zig build test-frontend`: catálogo, nulabilidad, controles
  escalares y protocolo del WASM compilado; requiere Node.
* `zig build check-aida -Dlibpq-prefix=...`: compila backend real y frontend sin ejecutarlos.
* `zig build test-aida-launcher`: prueba el arranque y cierre conjunto con procesos simulados
  (Python 3); `zig build run-aida -Dlibpq-prefix=...` inicia la aplicación configurada.
* `zig build test`: suite de runtime, asserts comptime, casos de no-compila y comprobación
  del snapshot aceptado. Las integraciones con servicios externos se ejecutan por separado.
* Desde `examples/aida/`, `zig build testing-backend` inicia el backend en memoria;
  `zig build test-backend` verifica su API HTTP con un proceso propio (requiere Python 3).
* `zig build test-model`: pruebas del modelo normalizado y sus consumidores, incluidos
  los rechazos de compilación correspondientes.
* `zig build test-postgres -Dlibpq-prefix=...` levanta un PostgreSQL descartable con Docker
  y prueba la ejecución real; queda separado para que la suite normal no requiera servicios.
* `zig build test-migrations -Dlibpq-prefix=... -Dliquibase-bin=...` fija Liquibase 5.0.4 y
  PostgreSQL 18.4, y prueba el historial aceptado, idempotencia, migraciones manuales,
  rollback y checksum.
* `zig build test-rest-postgres -Dlibpq-prefix=...` prueba el CRUD generado end-to-end con
  `std.http`, libpq y PostgreSQL descartable.
* `python3 test/integration/build_commands_test.py`: comprueba los nombres públicos del
  build mediante `--help`; no inicia aplicaciones ni aplica migraciones.

## Decisiones de diseño

* Las definiciones son valores comptime anónimos (structs literales); el equivalente del
  `satisfies` es `zigma.record(type_defs, .{...})`, que valida y devuelve el valor sin
  cambiarlo, conservando su tipo literal exacto (qué propiedades están presentes).
* Criterio DevXP: los controles se agregan si ayudan al que define un sistema con la
  librería a encontrar antes el problema, en el lugar donde está el error. Por eso
  `defineTypes(.{...})` valida la colección de tipos en el punto de declaración (acepta
  `zigma.TypeDef{...}` o la forma anónima estructuralmente igual); sin eso, una colección
  malformada recién fallaría donde se usa por primera vez. `anytype` acá es genericidad
  (los chequeos son comptime), no un `any`: Zig no permite declarar la cota del genérico
  en la firma, la cota se impone con estos chequeos.
* De la definición se derivan los tipos estáticos con funciones comptime
  (`RecordInstanceType`, `RecordInfoOf`, etc.): los campos se escriben una sola vez.
* Def → Info: `completeRecord` / `completeEntity` explicitan todos los defaults
  (`is_name: false`, `nullable: true`, label derivado del nombre con `_`→espacio,
  fks siempre en forma de mapa origen→destino, pk deduplicada).
* Las fks referencian la entidad destino **por nombre** (string): serializable y permite
  fks circulares y reflexivas. Chequeo local en `defineEntity` (campos origen, pk, uks);
  chequeo global en `defineEntities` (entidad destino existe, campos destino son su pk
  completa o una de sus uks). Los errores son `@compileError` con mensajes diseñados.
* En vez del spread de TypeScript: `zigma.merge(.{a, b})` para records y colecciones de
  tipos (dedup por nombre, gana el último, orden de primera aparición) y
  `zigma.mergePk(.{pk1, pk2})` para pks (dedup preservando orden). La concatenación con
  duplicados (`a.pk ++ b.pk`) también sirve como pk: `completeEntity` la deduplica.
* En el flujo versionado, las entidades son estado deseado y `db/schema.snapshot.json` es
  el último estado aceptado. Un mismatch falla el build. Los drafts llevan hashes SHA-256
  de ambos extremos; operaciones riesgosas quedan como `ZIGMA-BLOCKER` y nunca se infieren
  `CASCADE`, renames ni casts. Solo la reproducción en PostgreSQL y la igualdad de catálogo
  permiten mover el draft a `db/changes/` y reemplazar atómicamente el snapshot.

## Zig: versión y particularidades

* Compila con Zig 0.17.0-dev (ver `minimum_zig_version` en `build.zig.zon`). Esta versión
  tiene la API nueva de reflexión: `std.lang.Type` (arrays paralelos `field_names` /
  `field_types` / `field_attrs`), builtins `@Struct` y `@Tuple` en lugar de `@Type`,
  y `std.testing` sin `expectEqual`/`expectEqualDeep` (usar `expect` y
  `expectEqualStrings`). Ante dudas de API, la fuente de verdad es la std de la
  instalación local de zig.
* La palabra clave `comptime` en un scope ya comptime es **error** ("redundant
  comptime"). Como casi todo acá se usa tanto desde scope comptime (defs a nivel
  contenedor) como runtime (tests), no se puede usar `comptime` dentro de las funciones
  del framework. El truco usado: una const a nivel de contenedor de un struct generado
  (`PkMerge(pks).names`, `FkSources(fk).names`, `LabelHolder(name).label`) siempre se
  evalúa en scope comptime y su acceso es comptime-known también en contexto runtime.
* El matching de `expect_errors = .{ .contains = ... }` es **por línea**: el texto debe
  ser el final de alguna línea de error, o con el comodín `/?/` prefijo y sufijo de la
  línea. Solo el **primer** `/?/` de la línea es comodín y no hay regex: esas dos formas
  son todo el vocabulario. Para errores del framework se usa el mensaje completo; para
  errores nativos del compilador (cuyo final no es estable) el `expected` se escribe
  `at("fragmento.zig")`, que concatena en comptime el path del fragmento como prefijo con
  el separador del host (`std.fs.path.sep_str`: `\` en Windows, `/` en Linux), que es como
  lo imprime el compilador. Así los casos corren igual en cualquiera de los dos.
