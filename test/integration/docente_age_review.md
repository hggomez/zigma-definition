# Validación de edad de docente — verificación

Implementación realizada después de aprobar los casos preparados, el 29 de octubre
de 2026. El checkpoint incluyó 25 tests Zig, tres rechazos de compilación, un
servidor de contexto controlado y casos HTTP compartidos por ambos backends.

## Comportamiento

- `Fecha.ageOn(today)` devuelve años cumplidos, valida ambas fechas y rechaza un
  nacimiento futuro. Para el 29 de febrero se usa el 1 de marzo en años no bisiestos.
- `validarDocente(Docente, Fecha)` conserva la prioridad de cinco años de experiencia
  y luego exige nacimiento y treinta años para `teorico`. Mantiene la normalización
  de espacios y mayúsculas. Otros cargos pueden omitir el nacimiento.
- `BusinessValidator(T, Context)` recibe contexto explícito. El registro comprueba
  identidad exacta de la entidad y un mismo tipo de contexto para todos sus validadores.
  Sin validadores, `Api.ValidationContext` es `void`.
- `std_http.serve` obtiene el contexto una vez antes de llamar a la API. Un error
  del proveedor devuelve 500 sanitizado y no ejecuta la API. AIDA utiliza UTC−03:00
  fijo y renueva el día entre solicitudes, sin consultar el reloj por cada fila.
- POST rechaza antes de insertar. PUT combina y valida todas las filas antes de
  actualizar. Los códigos 422 distinguen experiencia, nacimiento ausente, edad
  insuficiente y nacimiento futuro. La validación civil HTTP conserva 400.

No se agregaron garantías transaccionales nuevas, ejecución automática de `rules`
ni validación local de edad en WASM. Los seeds y literales Zig no validan por sí solos.

## Suites y alcance

| Archivo | Casos |
| --- | --- |
| `test/docente_age_test.zig` | 8: cumpleaños exacto, bisiestos, fechas futuras/invalidas, precedencia de experiencia, nulos y campos ajenos. |
| `test/docente_age_rest_test.zig` | 9: códigos y mensajes, POST sin escritura, PUT parcial y múltiple, parámetros ISO, cleanup y GET sin validación retroactiva. |
| `test/validation_context_test.zig` | 8: identidad del contexto, renovación entre solicitudes, mismo contexto por PUT, contexto void y conversión del reloj en límites diarios, anuales y de rango. |
| `test/compile_errors/rest_validator_*context*.zig` | 3 rechazos específicos: contextos distintos, firma incompatible y otra identidad de fila. |
| `test/integration/context_server.zig` + `run_context_test.py` | HTTP real: una llamada al proveedor, renovación, fallo sanitizado sin ejecutar API y recuperación en la siguiente solicitud. |
| `test/integration/docente_age_http.py` | Mismos rechazos y aceptaciones en memoria y PostgreSQL; una actualización rechazada conserva datos, también con varias filas. |

## Baseline y adaptaciones

El contrato ya incluía `fecha_nacimiento` y la migración `000006`. Se conservaron
ambos, junto al snapshot aceptado y el seed de Luis con nacimiento 1990-05-14.

Antes de implementar:

- Build raíz, `check-aida` e integración PostgreSQL: pasan.
- `test-local`: cinco artefactos no compilaban por literales sin `fecha_nacimiento`;
  seis tests Zig ejecutados fallaban y el frontend tenía un fallo del DOM simulado.
- La integración REST fallaba en su JSON exacto, que no incluía `fecha_nacimiento`.

Se completaron los literales y el seed pendiente con valores explícitos; los casos
positivos de experiencia reciben un nacimiento válido y un día fijo. Se migraron
las firmas de callback/handler y sus diagnósticos. El JSON esperado incorpora el
campo agregado por el usuario. El fixture del frontend conserva también su fecha
nula al editar texto. No se regeneraron referencias históricas.

Los cinco fallos históricos restantes corresponden a:

1. `postgres_ddl_test`: FK reflexiva de docentes.
2. `postgres_ddl_test`: schema AIDA completo.
3. `model_consumers_test`: bootstrap AIDA contra referencia anterior al modelo.
4. `aida_schema_reference_test`: DDL baseline histórico.
5. `aida_schema_reference_test`: snapshot histórico.

Esas referencias son anteriores a `esImportador` y ahora también a
`fecha_nacimiento`. Permanecen visibles en la suite y sin cambios.

## Resultado

- Los 25 tests nuevos y los tres rechazos de compilación pasan.
- `test-local`: **199/204 tests Zig aprobados**, con los cinco fallos históricos;
  frontend **19/19**, pruebas de backend en memoria, contexto HTTP y lanzador aprobadas.
- Build raíz y `check-aida -Dlibpq-prefix=/opt/homebrew/opt/libpq`: aprobados.
- `test-postgres` y `test-rest-postgres` con ese prefijo: aprobados sobre bases
  descartables. Una ejecución de `test-postgres` tuvo un cierre de conexión al
  iniciar PostgreSQL; repetir la suite completa sin cambios pasó.
- Formato Zig, sintaxis Python/JavaScript/shell y `git diff --check`: aprobados.

DDL baseline, DDL bootstrap, snapshot, catálogo y `Model.info` fueron capturados
antes/después y coinciden byte por byte. SHA-256 de los artefactos idénticos:

```text
baseline.sql    0f2a4c19d1b01e860f4605223fc64d8edff9b066a6fea5b2cde7050fcb31ea8b
bootstrap.sql   673f041874023dfa5ace9273afb11563252efc0ff9af1b20c6185ede9f0ca08a
snapshot.json   ad7b33e81d0204f14e86c4ce6b7bea07afcc04ae65f24af663b1a467adfee717
catalog.json    2fd4608b73f7c5bf90d98d166cc24d62fc50fd9d0f0a8e408a74043b36cef57b
model-info.json 589aa93c5285ad019e52ac1d7102149cf55e240e204421944357748d926568ff
```

El snapshot versionado y `000006_add_docentes_fecha_nacimiento.sql` mantienen
también sus hashes iniciales. No se utilizó la base del usuario.
