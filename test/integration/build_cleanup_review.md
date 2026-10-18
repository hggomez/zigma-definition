# Verificación de la limpieza de ejemplos y build

## Checkpoint aprobado

Antes de modificar producción, `build_commands_test.py` ejecutó `zig build --help`:
cuatro rechazos esperados y un caso positivo. Faltaban `test-local` y `apply-migrations`,
y seguían publicados `run-postgres-bootstrap` y `run-postgres-liquibase-bootstrap`.
El usuario aprobó explícitamente este checkpoint. Los cinco casos pasan tras el cambio.

## Resultados comparados

| Comprobación | Baseline | Después |
| --- | --- | --- |
| Suite Zig `test` | Cinco fallos conocidos | Los mismos cinco, dentro de `test-local` |
| Frontend/WASM | 19/19 | 19/19, invocado desde `test-local` |
| Backend HTTP en memoria | Pasa | Pasa, invocado desde `test-local` |
| Lanzador | 17/17 | 17/17, invocado desde `test-local` |
| `check-aida` | Pasa | Pasa |
| Build raíz y schema aceptado | Comprobación incluida en `test` sin error | Pasa |
| `test-postgres` | Pasa | Pasa; bootstrap trasladado y mappings compartidos |
| `test-rest-postgres` | Falla antes del CRUD por `ConnectionFailed` | Mismo fallo de conexión |
| `test-migrations` | Liquibase no encuentra el changelog temporal absoluto | Mismo fallo; usa el ejecutable renombrado |
| Interfaz de comandos | Cuatro rojos esperados, un caso pasa | 5/5 |

La ejecución adicional con target explícito y optimización `safe` no se realizó:
su permiso fue rechazado. La configuración nativa habitual sí se verificó. El código
propaga target, CPU, formato, enlazador dinámico y optimización al consumidor.

Los fallos previos de la suite Zig son:

- `postgres_ddl_test`: `creates a reflexive foreign key inline` y
  `creates the complete AIDA schema in dependency order`.
- `aida_schema_reference_test`: comparaciones del baseline DDL y snapshot anteriores
  al modelo.
- `model_consumers_test`: comparación del bootstrap SQL anterior al modelo.

Los dos fallos de integración se reprodujeron antes de mover archivos. En REST, libpq
informa que el servidor cerró la conexión durante la preparación de la base; también
falló al repetir el baseline de esa suite por separado. En migraciones, Liquibase 5.0.4
informa `ChangeLogParseException` para el changelog copiado a un directorio temporal.
No se modificaron los scripts para ocultar esos errores ni se afirma haber completado
las aserciones posteriores de esas suites.

## Comprobación adicional de apply-migrations

Se creó un PostgreSQL descartable exclusivo y se esperó a que aceptara TCP. Desde la
raíz se ejecutó `zig build apply-migrations` con sus credenciales descartables y
`LIQUIBASE_CHANGELOG=db/changelog-root.yaml`, dos veces. Resultado:

- Primera ejecución: cinco changesets aplicados.
- Segunda ejecución: cero nuevos, cinco previamente aplicados.
- Filas del historial, orden y checksums idénticos después de ambas ejecuciones.
- El validador PostgreSQL confirmó que el schema coincide con el contrato compilado.
- El contenedor se eliminó al terminar; no se utilizó la base del usuario.

## Artefactos preservados

Se capturaron los artefactos generados desde el árbol actual antes de la limpieza,
sin regenerar las referencias históricas. La comparación byte por byte antes/después
dio igualdad para los tres:

| Artefacto | SHA-256 antes y después |
| --- | --- |
| DDL baseline | `bf7e2f636dd0bf5d8cb48854eaa77c855ce42acb10ff7f0fc014852ac3212ec8` |
| DDL bootstrap | `590ba0ad25b46ed59cf49419ea4703fb1059e7b75c935248a3c75ca85ccff241` |
| Snapshot | `2271a0b9f066067a5e013e087ae82ab0607327bc64296877071983c0c522e7a4` |

También se comprobaron los hashes del core, del contrato AIDA, de todos los archivos
de `db/` y de las referencias históricas: permanecen sin cambios.
