# zigma-definition

Port a Zig del módulo `system-design` (TypeScript): la parte descriptiva del framework
SSOTIGAD (Single Source Of Truth Implies Good Application Design). Provee el vocabulario
para describir sistemas (tipos de dominio, entidades, campos, pks, uks, fks) de modo que
generadores automáticos puedan derivar tablas, endpoints, pantallas, serializadores y
validadores. Este módulo cubre **solo la parte descriptiva**: no genera nada.

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

* `src/zigma.zig`: el framework descriptor (módulo `zigma`). No conoce ningún sistema concreto.
* `examples/aida.zig`: el sistema de alumnos descripto con el framework, y
  `examples/aida_seed.sql`, sus filas de ejemplo. Son los únicos archivos que nombran a
  aida fuera de los tests: lo generado sale de `src/generate.zig`, genérico, compilado
  con el sistema como módulo `"system"` (`generate schema | dml | dml-tests | server |
  frontend DIR | rules-ts | env`); cada artefacto exige lo que el sistema declara (`name`,
  `type_defs`, `entity_defs`, `rule_defs`).
* `build.zig`: crear una instancia del framework. No nombra ningún sistema: lo recibe por
  línea de comandos. `zig build up -Dsystem=examples/aida.zig
  [-Dseed=examples/aida_seed.sql]` genera todo, levanta el stack de la instancia (proyecto
  compose `zigma-<nombre>`, `docker-compose.instance.yml` encima de `docker-compose.yml`:
  frontend en 8081, backend en 3001, Postgres en 5433) y resetea su base (esquema + seed
  si hay); queda corriendo hasta `zig build down -Dsystem=...`. También `print-schema` y
  `create-database`. Sin `-Dsystem` los pasos fallan con un mensaje. Expone como `pub fn`
  el cableado (módulos del framework, generador, archivos generados, stacks de compose)
  que reusan los tests.
* Los nombres de la infra salen del sistema: `generate env` escribe `.env` (gitignoreado,
  `SYSTEM_NAME=<name>`) antes de todo `docker compose`, y los compose lo interpolan
  (contenedor, usuario/base de Postgres, volumen, proyecto de la instancia). `psql` corre
  por el servicio (`docker compose exec -T postgres`) con el `POSTGRES_USER` /
  `POSTGRES_DB` del contenedor.
* `test/build.zig` (+ `test/build.zig.zon`): los tests, con aida como ejemplo. Es un
  paquete propio que depende del raíz (`.path = ".."`) y reusa sus `pub fn` pasándoles el
  builder del raíz; no puede estar junto a `build.zig`: dos build scripts en el mismo
  directorio comparten el runner cacheado (el segundo recibe los pasos del primero). Se
  corre **desde la raíz** (los paths de los errores de compilación esperados son relativos
  al directorio desde el que se invoca): `zig build --build-file test/build.zig <paso>`.
* `test/zigma_test.zig`: los tests positivos (runtime y asserts comptime).
* `test/compile_errors/*.zig`: fragmentos que **deben fallar** la compilación;
  `test/build.zig` los compila con `expect_errors` (el paso tiene éxito solo si el error
  coincide) y los cuelga del step `test`. La lista de casos con su mensaje esperado está en
  `test/build.zig`.
* `zig build --build-file test/build.zig test` corre los tests de Zig: tests de runtime y
  casos de no-compila (sin Node ni Docker). `test-all` corre `test` y después, de a uno y
  cada uno en su propio proceso `zig build`, los que necesitan Node o Docker:
  `test-backend` (`dml.ts` con `node --test`), `test-backend-db` (`dml.ts` contra Postgres
  desde el contenedor del backend, con los valores que le pasa el servidor, sin HTTP),
  `test-api` (el servidor en su contenedor), `test-e2e` (Playwright) y `test-rules-wasm`.
  Cada uno se puede correr suelto. Usan el stack de test (`docker-compose.yml` solo,
  8080/3000/5432).
* `test-example`: lo que deja `up` con aida y su seed, chequeado por
  `test/example_stack_test.zig` (exactamente las filas del seed); el stack queda corriendo.
  No está en `test-all`.
* `src/rules.zig` (`defineRules`, re-exportado por `zigma`), `src/rules_wasm.zig` (las reglas
  de un sistema compiladas a un `.wasm`) y `src/ts_rules_generator.zig` (`rules.ts`); sus
  tests usan `test/test_system.zig`, un sistema propio de prueba. `test-rules-wasm` prueba
  el `.wasm` y el `rules.ts` desde Node (fuera de `test`).

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
* Reglas: una regla es siempre una validación, `fn(RecordInstanceType(type_defs, record))
  error{...}!void`, declarada con `zigma.defineRules(type_defs, .{ .nombre = .{ .record,
  .rule } })`; el record va explícito (el tipo del parámetro perdió dominios y `nullable`).
  Se corren desde TS compiladas a WASM (un `.wasm` por sistema, exports por comptime, JSON
  de entrada, `""` / nombre del error / `"InvalidInput"` de salida); `rules.ts` devuelve
  `{ ok: true } | { ok: false; error }` y confía en los tipos TS de su argumento. Cuándo se
  aplica una regla queda para más adelante.
* En vez del spread de TypeScript: `zigma.merge(.{a, b})` para records y colecciones de
  tipos (dedup por nombre, gana el último, orden de primera aparición) y
  `zigma.mergePk(.{pk1, pk2})` para pks (dedup preservando orden). La concatenación con
  duplicados (`a.pk ++ b.pk`) también sirve como pk: `completeEntity` la deduplica.

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
