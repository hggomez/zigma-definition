# Checkpoint: retirar Projection y validar entidades concretas

Estado: **checkpoint aprobado e implementación verificada**. El usuario autorizó
continuar con los tests presentados. Las secciones de baseline y rojos conservan
la evidencia anterior al cambio; la verificación final figura al pie.

Este checkpoint corresponde al plan de eliminación de `Projection`/`RuleInput` y
validadores REST que reciben entidades concretas. Se conservaron los cambios que
ya existían en el árbol. Hasta este punto solo se agregaron pruebas, sus fixtures,
el registro de esas pruebas en `build/tests.zig` y este documento.

## Baseline observado

Se utilizó Zig `0.17.0-dev.1818+7051f8e73`, sin modificar su versión.

| Comando | Resultado anterior a los tests nuevos |
| --- | --- |
| `zig build test-local --summary all` | Falla: cinco expectativas históricas de PostgreSQL y referencias a símbolos retirados de AIDA. |
| `zig build` | Pasa; el snapshot aceptado está vigente. |
| `zig build check-aida -Dlibpq-prefix=/opt/homebrew/opt/libpq` | No compila: el adaptador REST todavía llama a `aida.validarDocente`, ausente del contrato actual. |

Los cinco fallos históricos son dos expectativas de `postgres_ddl_test`, dos de
`aida_schema_reference_test` y una de `model_consumers_test`. No se modificaron
las referencias de DDL/snapshot para ocultarlos.

Los errores de compilación adicionales ya estaban presentes antes del checkpoint:

- `test/aida_test.zig`: referencias a `DefinedType`, `DocenteBusinessState` y
  `validarDocente`.
- `test/concrete_entity_test.zig`, `test/json_test.zig` y el rechazo
  `defined_type_wrong_field_type.zig`: referencias a `DefinedType`.
- `examples/aida/src/rest.zig`: referencia a `validarDocente`; bloquea también las
  suites y compilaciones que utilizan el backend de AIDA.

El baseline local terminó con `96/113 steps succeeded (9 failed)` y
`68/73 tests passed (5 failed)`. Los fallos de compilación se cuentan como pasos,
no como aserciones ejecutadas.

## Artefactos actuales capturados

Directorio temporal (no reemplaza referencias versionadas):
`/var/folders/vf/99x_j2t54v5bw2_rfcnbtmvc0000gn/T/zigma-concrete-validation-t3u3ha_i`.

Contiene `capture.sh`, `capture.zig`, `before/`, `after/` y logs del baseline.
Al terminar se repetirá la captura en `after/` y se comparará byte por byte.

| Archivo en `before/` | SHA-256 |
| --- | --- |
| `baseline.sql` | `bf7e2f636dd0bf5d8cb48854eaa77c855ce42acb10ff7f0fc014852ac3212ec8` |
| `bootstrap.sql` | `590ba0ad25b46ed59cf49419ea4703fb1059e7b75c935248a3c75ca85ccff241` |
| `snapshot.json` | `2271a0b9f066067a5e013e087ae82ab0607327bc64296877071983c0c522e7a4` |
| `catalog.json` | `60c797c5a00943d1c408eee01ff709af5c1876abc40bbb65d4e5bcc0bc1b2d38` |
| `model-info.json` | `dfa26de4aacec1bc948df342e94977a76c0ee0b5da31abd07f2e1007a21da868` |

## Tests preparados

[`test/typed_business_validation_test.zig`](../typed_business_validation_test.zig)
contiene **18 tests**:

| Grupo | Casos |
| --- | --- |
| API y modelo | Identidad exacta del parámetro; retiro de los factories conservando reglas, patch y filtros: 2. |
| POST | Escalares y `Fecha` reales con parámetros textuales; nullable omitidos; violación sin escritura: 3. |
| PUT | Dependencias combinadas con el estado actual; asignar null; validar varias filas antes de escribir; asignar valores a campos antes nulos; cero coincidencias: 5. |
| Ausencia de ejecución | Entidades sin validador; GET y DELETE: 2. |
| Datos inválidos | Valores almacenados/nulabilidad; columnas y ancho de fila; JSON del codec incompatible con el dominio: 3. |
| Memoria | Propagación de `OutOfMemory` del decoder en POST y PUT, con cleanup del resultado seleccionado: 2. |
| AIDA | REST utiliza la regla concreta de docente y conserva código/mensaje públicos: 1. |

El repositorio auxiliar en
[`test/fixtures/validation_repository.zig`](../fixtures/validation_repository.zig)
continúa intercambiando texto/null. Sus resultados copian los datos a una arena,
registran `deinit()` y cuentan escrituras. Las pruebas usan `std.testing.allocator`.
El observador compara las filas dentro de la llamada al validador, sin retener
referencias a memoria temporal.

Se agregaron **cuatro rechazos de compilación**:

1. Registrar el validador de otra entidad.
2. Registrar un struct manual de la misma forma pero distinta identidad.
3. Recibir `[]const FieldValue` en vez de la entidad concreta.
4. Devolver `bool` en vez de `?BusinessRuleViolation`.

Además, se actualizó el diagnóstico esperado de `rest_business_validator_invalid`
para mencionar `BusinessValidator(Model.Row("things"))`. Se conserva el rechazo
existente de entidad desconocida.

Los casos de firma usan un fixture separado: un error por falta del factory queda
ubicado allí y **no** satisface el diagnóstico del literal inválido. Los otros dos
casos nuevos exigen el mensaje completo del registro tipado.

## Resultado rojo verificado

- La suite nueva no puede compilar porque `BusinessValidator` todavía es un struct
  monomórfico y `aida.validarDocente` no existe. No se presentan sus 18 casos como
  18 aserciones ejecutadas y fallidas.
- Ejecutado por separado con `--test-filter 'model retains rule metadata'`, el test
  del modelo **sí compila y falla** porque `Projection` todavía está publicado.
- Los cuatro rechazos nuevos están rojos: la ausencia del factory no coincide con
  sus diagnósticos esperados. El rechazo existente actualizado también está rojo.
- `zig build test --summary all` conserva además los fallos previos. Resultado:
  `91/113 steps succeeded (14 failed); 12/17 tests passed (5 failed)`.
- Formato de los archivos Zig nuevos/modificados y `git diff --check`: correctos.

Logs: `baseline-local.log`, `baseline-build.log`, `baseline-check.log`,
`red-model-api.log` y `red-tests.log`, en el directorio temporal indicado arriba.

## Implementación y verificación final

Se implementó `BusinessValidator(T)` y el registro comprueba su identidad exacta
contra `Model.Row(entity)`. REST convierte filas completas mediante los codecs
existentes y `std.json.parseFromValueLeaky`, antes de llamar al validador. La nueva
conversión propaga `OutOfMemory` y sanitiza los errores internos. Los repositorios
conservan sus parámetros textuales y sus APIs.

AIDA utiliza una única `validarDocente(Docente)`, conservando sus nueve casos de
negocio y la prueba de campos ajenos a la regla. Se retiraron `Projection`,
`RuleInput`, el callback textual y `BusinessValidationError` de la API pública.
Se conservaron los metadatos `rules` y todos sus rechazos legítimos. Los casos
antiguos de `DefinedType` se migraron a `Cargo`/`RecordInstanceType`; los fragmentos
de rechazo ahora se llaman `cargo_wrong_field_type` y `cargo_unknown_field`.

| Verificación | Resultado |
| --- | --- |
| Suite nueva | **18/18 tests pasan**, con `std.testing.allocator`. |
| Rechazos nuevos | **4/4 pasan con el diagnóstico previsto**; también pasa el diagnóstico actualizado y el rechazo de entidad desconocida. |
| `zig build test-model test-local --summary all` | `144/149 tests passed (5 failed)`: únicamente los cinco fallos históricos del baseline, sin errores de compilación. |
| Consumidor AIDA | Backend en memoria y 19 tests Node/WASM pasan; el lanzador y los comandos públicos también pasan. |
| `zig build` | Pasa; snapshot aceptado vigente. |
| `zig build check-aida test-postgres test-rest-postgres -Dlibpq-prefix=/opt/homebrew/opt/libpq --summary all` | **13/13 pasos pasan**, con bases y puertos descartables. |
| Comparación de artefactos | Los cinco archivos de `after/` son idénticos byte por byte a `before/`; sus hashes coinciden con la tabla anterior. |
| Formato y sintaxis | `zig fmt --check`, `sh -n` del script modificado y `git diff --check` pasan. |

La integración REST conserva la comparación exacta del JSON de docente e incluye
`esImportador`. Además verifica POST rechazado sin insertar, PUT aceptado con
booleano false, PUT rechazado al bajar la experiencia y lectura posterior sin
cambios. Se actualizaron README, referencia de APIs, guía del núcleo, documentación
de validadores y mapas de agentes.

No se modificaron el contrato de campos, SQL, migraciones aceptadas, snapshot
versionado, referencias históricas ni versión de Zig. El binding automático de
`rules`, los codecs/repositorios tipados y la atomicidad del PUT siguen pendientes.

Logs finales en el mismo directorio temporal: `typed-tests.log`, `after-local.log`,
`after-integrations.log`, `after-build.log` y `capture-after.log`.
