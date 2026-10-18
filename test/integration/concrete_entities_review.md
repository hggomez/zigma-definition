# Checkpoint: entidades como tipos concretos

Estado: **checkpoint aprobado e implementación verificada**. El usuario autorizó
continuar después de revisar los rojos. Se implementaron `Entity`, el registro y la
migración de AIDA en `dev-tipos-concretos`. Las secciones de baseline y rojos conservan
el resultado anterior a la implementación; la verificación final figura al pie.

## Preparación y baseline

Se partió de `08a97b5578e19f6ae9949231ba202c87bdf3c4fb`, con el árbol limpio.
Se corrigieron las referencias activas a `tools/` en build, empaquetado y documentación
para apuntar a `migration_tools/`. No se modificó la lógica de migraciones.

Baseline ejecutado después de corregir esas rutas y antes de agregar los tests:

| Comando | Resultado |
| --- | --- |
| `zig build test-local` | Cinco fallos históricos de expectativas previas a `esImportador`; las suites del consumidor, lanzador y comandos pasan. |
| `zig build` | Pasa. |
| `zig build check-aida -Dlibpq-prefix=/opt/homebrew/opt/libpq` | Pasa. |
| `zig build test-postgres -Dlibpq-prefix=/opt/homebrew/opt/libpq` | Pasa contra PostgreSQL descartable. |
| `zig build test-rest-postgres -Dlibpq-prefix=/opt/homebrew/opt/libpq` | Falla: la expectativa del POST no incluye `"esImportador":null`. |
| `zig build test-migrations -Dlibpq-prefix=/opt/homebrew/opt/libpq -Dliquibase-bin=/Users/jgrandoso/tools/liquibase-5.0.4/liquibase` | Falla: Liquibase informa `ChangeLogParseException` porque no encuentra el changelog bajo una ruta temporal absoluta. |

Las tres integraciones se invocaron juntas, como pasos independientes del mismo build.
No se utilizó la base del usuario. Los dos fallos de integración ya existían antes
de modificar el núcleo y quedan registrados separadamente de los cinco locales:

1. `postgres_ddl_test`: FK reflexiva de docentes.
2. `postgres_ddl_test`: DDL completo de AIDA.
3. `aida_schema_reference_test`: referencia de baseline DDL.
4. `aida_schema_reference_test`: referencia de snapshot.
5. `model_consumers_test`: referencia de bootstrap DDL.

Logs locales de esta ejecución:

- `/tmp/zigma-entities-before-local.log`
- `/tmp/zigma-entities-before-build.log`
- `/tmp/zigma-entities-before-check.log`
- `/tmp/zigma-entities-before-integrations.log`

## Artefactos de comparación

Se capturaron los resultados **actuales**, sin reemplazar las referencias históricas
de `test/fixtures/` ni el snapshot de `db/`. Directorio temporal:
`/tmp/zigma-entities-comparison-96rplb8w`.

`capture.zig` y `capture.sh` permiten repetir la captura después del refactor en
`after/` y compararla byte por byte con `before/`. Incluye también `Model.info`:

| Archivo en `before/` | SHA-256 |
| --- | --- |
| `baseline.sql` | `bf7e2f636dd0bf5d8cb48854eaa77c855ce42acb10ff7f0fc014852ac3212ec8` |
| `bootstrap.sql` | `590ba0ad25b46ed59cf49419ea4703fb1059e7b75c935248a3c75ca85ccff241` |
| `snapshot.json` | `2271a0b9f066067a5e013e087ae82ab0607327bc64296877071983c0c522e7a4` |
| `catalog.json` | `60c797c5a00943d1c408eee01ff709af5c1876abc40bbb65d4e5bcc0bc1b2d38` |
| `model-info.json` | `dfa26de4aacec1bc948df342e94977a76c0ee0b5da31abd07f2e1007a21da868` |

## Tests nuevos

[`test/concrete_entity_test.zig`](../concrete_entity_test.zig) declara **14 tests**:

1. Usar una entidad en funciones y arrays sin construir `Framework`.
2. Conservar dominios, incluyendo uno personalizado, y distinguir nulabilidad del
   record frente a PK simples y compuestas de entidad.
3. Generar exclusivamente campos de datos, sin defaults, campos comptime ni
   declaraciones internas de metadatos.
4. Normalizar definiciones descriptivas con colecciones omitidas y PK duplicada.
5. Extraer PK desde la definición preservando los metadatos originales del record.
6. Obtener exactamente el tipo registrado desde `Row`, con y sin `defineEntities`.
7. Conservar las FK reflexivas, mapas normalizados, UK y dependencias de reglas.
8. Admitir relaciones circulares por nombre, hacia PK y UK completas.
9. Conservar tipos, orden y nulabilidad de `Projection` y `RuleInput`, incluyendo
   proyecciones vacías.
10. Conservar las diferencias entre omisión, null, false, cero y texto en patches y filtros.
11. Serializar una instancia con `std.json` sin campos adicionales ni wrappers.
12. Serializar `Model.info` exactamente como la definición normalizada, sin tipos
    ni el registro de asociaciones.
13. Publicar y registrar los once tipos concretos de AIDA; conservar Cargo como record.
14. Tipar los arrays de seeds con las entidades y usarlas en la validación de fila completa.

Fixture independiente de AIDA:
[`test/compile_errors/fixtures/concrete_entities.zig`](../compile_errors/fixtures/concrete_entities.zig).

Los **22 rechazos de compilación** se registran en `entity_compile_error_cases` de
[`build/tests.zig`](../../build/tests.zig). Cubren:

| Grupo | Casos |
| --- | --- |
| Registro malformado | Colección inválida, entrada inválida, Type ausente, definición ausente, Type que no es tipo Zig, propiedad desconocida y definición inválida: 7. |
| Comprobaciones de Framework | Registro sin validar, struct manual de igual forma pero distinta identidad, cambio de nulabilidad, cambio de dominio y FK desconocida sin `defineEntities`: 5. |
| Entity independiente | Dominio desconocido, dominio opcional sin `defineTypes`, PK inválida y dependencia de regla inexistente: 4. |
| Instanciación | Campo obligatorio ausente, nullable ausente, PK null, valor de tipo incorrecto y campo desconocido: 5. |
| DDL | El ciclo admitido por el núcleo conserva el rechazo específico del generador SQL: 1. |

Los mensajes controlados por el framework se comparan explícitamente. Para el campo
desconocido, cuyo mensaje nativo incluye el nombre interno del tipo, se exige que el
error se ubique en el literal de instancia. Un error en el fixture por falta de
`Entity` **no** satisface ese caso.

Las pruebas existentes de las tres validaciones de docente, HTTP, JSON, seeds y CRUD
se mantienen. Se migrarán sus contratos auxiliares después de aprobar este checkpoint,
sin eliminar los rechazos existentes ni debilitar sus verificaciones.

## Resultado del checkpoint rojo

Ejecutado: `zig build test-model --summary all`.
Log: `/tmp/zigma-entities-red-model.log`.

- La suite de 14 tests no llega a ejecutarse: faltan `Entity` y `aida.Docente`, y
  `completeEntity` todavía exige colecciones que la nueva API permite omitir.
- Los 22 nuevos casos de rechazo están rojos: el error actual no coincide con el
  diagnóstico exigido. Ninguno pasa accidentalmente por una API ausente.
- Los 16 rechazos anteriores de `test-model` pasan.
- Persisten los tres fallos históricos incluidos en `test-model` (baseline,
  bootstrap y snapshot); los otros dos locales pertenecen a la suite DDL.

El resumen del build es `24/51 steps succeeded (25 failed)`; son una compilación
de suite nueva, 22 rechazos nuevos y dos ejecutables de tests con tres fallos
históricos. No equivale a 25 aserciones nuevas fallidas.

Este conjunto se presentó para la revisión requerida por `CLAUDE.md` antes de
modificar el núcleo. Después de su aprobación se implementó la nueva API y se
migraron los consumidores y contratos auxiliares.

## Verificación final

- Los **14 tests nuevos pasan**; incluyen los once tipos de AIDA, sus seeds y la
  firma `validarDocenteRow(Docente)`.
- Los **22 rechazos nuevos pasan con el diagnóstico previsto**. También pasan los
  45 rechazos anteriores, migrados a `Entity` y al registro de asociaciones.
- `test-local` reproduce únicamente los cinco fallos locales del baseline.
  Su resumen es `107/113 steps succeeded (3 failed); 132/137 tests passed (5 failed)`;
  el número de tests informado no cuenta las suites Zig recuperadas de caché.
- Las 19 pruebas de frontend, el CRUD del backend en memoria, las 17 pruebas del
  lanzador y las 5 de comandos pasan dentro de `test-local`.
- El build raíz, `check-aida` con libpq y `test-postgres` pasan.
- Formato Zig/ZON y `git diff --check` pasan.
- `test-rest-postgres` reproduce la misma diferencia del JSON por `esImportador`.
- `test-migrations` reproduce el mismo `ChangeLogParseException` del changelog
  temporal. Su fallo impide verificar los pasos posteriores de esa integración;
  no se informa como exitosa ni se modifica su lógica dentro de este refactor.
- Los cinco archivos capturados en `after/` son idénticos byte por byte a
  `before/` y conservan los SHA-256 indicados arriba. No se modificaron los
  artefactos aceptados de `db/` ni las referencias históricas de `test/fixtures/`.

Logs posteriores: `/tmp/zigma-entities-after-local.log`,
`/tmp/zigma-entities-after-build.log`, `/tmp/zigma-entities-after-check.log` y
`/tmp/zigma-entities-after-integrations.log`. La ejecución directa de los 14 tests
también quedó en `/tmp/zigma-entities-core.log`.

`defineEntity` fue retirado sin alias; `Entity` y `Framework` comparten
`completeEntity` para normalizar. Las APIs de REST, JSON, frontend y PostgreSQL
siguen recibiendo `Model`; `Model.Row` devuelve el tipo registrado. No se agregaron
codecs o repositorios tipados ni ejecución automática de reglas.
