# Checkpoint: validación civil de Fecha

Estado: checkpoint aprobado por el usuario e implementación completada.
Las secciones de baseline y rojos conservan lo observado antes de modificar
producción; la verificación final figura al cierre. Los cambios previos del usuario
en README.md y DOCS.md se conservaron.

## Baseline observado

Compilador: Zig `0.17.0-dev.1818+7051f8e73`, sin cambiar la versión del proyecto.

| Comprobación | Resultado antes de agregar las pruebas |
| --- | --- |
| `zig build test-local` | 144/149 tests Zig pasan; cinco fallos históricos. Backend en memoria, frontend, lanzador y nombres de comandos pasan. |
| `zig build` | Pasa. |
| `zig build check-aida -Dlibpq-prefix=/opt/homebrew/opt/libpq` | Pasa. |
| `zig build test-postgres -Dlibpq-prefix=/opt/homebrew/opt/libpq` | Pasa con base descartable. |
| `zig build test-rest-postgres -Dlibpq-prefix=/opt/homebrew/opt/libpq` | Pasa al repetir aisladamente; el primer intento perdió la conexión durante el arranque del contenedor, antes de las solicitudes HTTP. |

Los cinco fallos históricos corresponden a las referencias anteriores a
`esImportador`: dos en `postgres_ddl_test.zig`, dos en
`aida_schema_reference_test.zig` y uno en `model_consumers_test.zig`.
No se actualizaron esas expectativas ni sus fixtures.

## Conjunto nuevo

Son **25 tests Zig nuevos**, registrados en `test` y por lo tanto en `test-local`:

| Archivo | Casos | Cobertura | Resultado en el checkpoint |
| --- | --- | --- | --- |
| `test/fecha_test.zig` | 6 | Rango 1–9999, componentes inválidos, bisiestos gregorianos, límites de cada mes, ISO ASCII estricto, ceros iniciales, round trips y comptime. | No compilan: faltan `Fecha.validate`, `fromIso` y `toIso`. |
| `test/fecha_codec_test.zig` | 6 | ISO y objeto JSON en query, objeto en body, rechazo de fechas imposibles, orden año/mes/día, ownership y fallos de asignación. | 3 pasan y 3 fallan. |
| `test/fecha_rest_test.zig` | 13 | POST/PUT/filtros antes de consultar o escribir; null sin codec; valores válidos; errores almacenados sanitizados; propagación de memoria y cleanup. Usa un contrato auxiliar con y sin validador. | 3 pasan y 10 fallan. |

Además:

- `test/aida_rest_test.zig`: se actualizó el caso que aceptaba `2025-02-30`.
  Ahora exige `InvalidValue` y falla con la implementación actual. Sus otros dos
  tests pasan.
- `test/integration/run_testing_backend.py`: exige 400 para fechas inválidas,
  comprueba que POST no cree una fila y que PUT o filtros rechazados no alteren el
  estado. Conserva las comprobaciones de null y agrega extremos, bisiesto y ambos
  formatos de query. Falla porque POST de `2025-02-30` devuelve 201.
- `test/integration/run_rest_postgres.sh`: reemplaza la aceptación 400/409/500
  por 400 con cuerpo exacto, comprueba el estado y las conversiones válidas
  equivalentes. Falla porque la fecha imposible llega a PostgreSQL y devuelve 500
  `database_error`.

Los tests REST distinguen dos errores 500 existentes: `invalid_repository_result`
al serializar, y `business_validation_error` al preparar una entidad para su
validador. Comprobar una fecha de dominio no agrega una regla de negocio.

Los tests de memoria inyectan `OutOfMemory` en codecs y recorren fallos de
asignación con `std.testing.checkAllAllocationFailures`. Un allocator de fixture
falla una sola reserva y permite las siguientes: así detecta el 400 incorrecto
que ocultaba una falta de memoria durante el parsing. Las pruebas del checkpoint
también detectan la conversión incorrecta a 500 al serializar y `WriteFailed`
proveniente del escritor con allocator.

Los resultados nuevos fueron rojos por ausencia de la API de dominio o por
comportamiento observable incorrecto, separados de los cinco fallos históricos.
Los tests de runtime nuevos compilan; no se detectaron fugas con
`std.testing.allocator` en estas ejecuciones.

## Artefactos para comparar después

Se capturaron los artefactos actuales, sin regenerar referencias históricas, en
`/tmp/zigma-fecha-validation-kvsp6lbn/before/`. En el mismo directorio temporal
están el capturador y los logs de baseline y tests rojos.

| Artefacto | SHA-256 antes del cambio |
| --- | --- |
| DDL baseline | `bf7e2f636dd0bf5d8cb48854eaa77c855ce42acb10ff7f0fc014852ac3212ec8` |
| DDL bootstrap | `590ba0ad25b46ed59cf49419ea4703fb1059e7b75c935248a3c75ca85ccff241` |
| Snapshot | `2271a0b9f066067a5e013e087ae82ab0607327bc64296877071983c0c522e7a4` |
| Catálogo | `60c797c5a00943d1c408eee01ff709af5c1876abc40bbb65d4e5bcc0bc1b2d38` |
| Model.info | `dfa26de4aacec1bc948df342e94977a76c0ee0b5da31abd07f2e1007a21da868` |

Formato Zig de archivos modificados, sintaxis Python/shell y `git diff --check`
pasan. No se modificaron migraciones, snapshot aceptado ni referencias históricas.

## Implementación y verificación final

`Fecha` implementa `validate`, `fromIso` y `toIso` con un único conjunto de reglas
gregorianas para años de 1 a 9999. `fecha_wire.zig` delega esas reglas al dominio,
copia los diez bytes ISO al allocator recibido y construye directamente el objeto
JSON de salida. REST conserva `OutOfMemory` desde parsing, codecs y escritura JSON.

Se corrigió un error del propio test de memoria de PUT: su URL no incluía ningún
filtro, por lo que recibía correctamente un 400 antes de alcanzar el codec. Ahora
usa `?id=1`; mantiene la expectativa `OutOfMemory` y cero llamadas al repositorio.
No se debilitó ninguna comprobación aprobada.

| Comprobación | Resultado final |
| --- | --- |
| Nuevos tests de Fecha | 25/25 pasan: 6 de dominio, 6 de codecs y 13 de REST. |
| `test/aida_rest_test.zig` | 3/3 pasan, incluido el rechazo de `2025-02-30`. |
| `zig build test-local` | 169/174 tests Zig pasan; solo los mismos cinco fallos históricos. Backend en memoria, frontend, lanzador y comandos pasan. |
| `zig build` | Pasa; snapshot aceptado vigente. |
| `zig build check-aida -Dlibpq-prefix=/opt/homebrew/opt/libpq` | Pasa. |
| `zig build test-postgres -Dlibpq-prefix=/opt/homebrew/opt/libpq` | Pasa con base descartable. |
| `zig build test-rest-postgres -Dlibpq-prefix=/opt/homebrew/opt/libpq` | Pasa con base descartable, 400 exacto, estado conservado, null, extremos de año y ambos formatos de filtros. |

Los artefactos de `before/` y `after/` son idénticos byte por byte: DDL baseline,
DDL bootstrap, snapshot, catálogo y Model.info mantienen los hashes registrados
arriba. No se modificaron migraciones, snapshot aceptado ni referencias históricas.
Formato Zig de archivos modificados, sintaxis Python/shell y `git diff --check` pasan.

README, DOCS, la guía del frontend y el mapa de agentes documentan el resultado.
WASM sigue sin validación civil local y los literales Zig requieren validación
explícita. Los repositorios conservan su frontera textual y las reglas de negocio
mantienen HTTP 422.
