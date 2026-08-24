# zigma-definition

Port a Zig del módulo `system-design` (TypeScript): la parte descriptiva del framework
SSOTIGAD (Single Source Of Truth Implies Good Application Design). Provee el vocabulario
para describir sistemas (tipos de dominio, entidades, campos, pks, uks, fks) de modo que
generadores automáticos puedan derivar tablas, endpoints, pantallas, serializadores y
validadores. El núcleo `zigma` cubre **solo la parte descriptiva**; la generación y ejecución
PostgreSQL viven en módulos independientes.

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
* `src/postgres_ddl.zig`: generación comptime del DDL inicial (módulo
  `zigma_postgres_ddl`).
* `src/postgres_executor.zig`: ejecución transaccional independiente del driver (módulo
  `zigma_postgres_executor`).
* `src/postgres_libpq.zig`: adaptador bloqueante opcional sobre `libpq` (módulo
  `zigma_postgres_libpq`).
* `examples/aida.zig`: el sistema de alumnos descripto con el framework (módulo `aida`).
* `examples/postgres_bootstrap.zig`: ejecutable que genera el DDL de AIDA en compilación y
  lo aplica usando `DATABASE_URL` en runtime.
* `test/*_test.zig`: tests positivos (runtime y asserts comptime).
* `test/compile_errors/*.zig`: fragmentos que **deben fallar** la compilación; `build.zig`
  los compila con `expect_errors` (el paso tiene éxito solo si el error coincide) y los
  cuelga del step `test`. La lista de casos con su mensaje esperado está en `build.zig`.
* `zig build test` corre todo: tests de runtime y casos de no-compila.
* `zig build test-postgres -Dlibpq-prefix=...` levanta un PostgreSQL descartable con Docker
  y prueba la ejecución real; queda separado para que la suite normal no requiera servicios.

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
