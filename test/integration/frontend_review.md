# Revisión del refactor JSON y frontend

Este checkpoint agrega pruebas antes de modificar producción. Los cambios previos
del arranque conjunto y la configuración del frontend se conservan.

## Resultados del checkpoint

| Conjunto | Resultado antes de implementar |
| --- | --- |
| JSON: 20 casos anteriores + 4 nuevos | 20 pasan; los 4 nuevos fallan por escaping/capacidad. |
| Catálogo con Model: 6 casos nuevos | Bloqueados en compilación por las firmas pendientes; aún no se ejecutaron sus asserts. |
| Frontend WASM y controles: 19 casos | 4 pasan y 15 fallan por el comportamiento previsto. |
| Integración HTTP ampliada | Pasa con proceso y puerto propios. |

Formato Zig, sintaxis del runner Node y `git diff --check` pasan. Las comprobaciones
visuales de navegador se ejecutarán después de implementar, con la lista inferior.

## Ejecución automática

Desde la raíz:

```sh
zig build test-json --summary all
```

Desde `examples/aida`:

```sh
zig build test-frontend --summary all
zig build test-backend --summary all
```

`test-json` ejecuta las pruebas JSON anteriores y los nuevos casos de escaping y
capacidad. Otro ejecutable verifica las firmas basadas en `Model`, nulabilidad,
orden, campos anidados, relaciones y exclusión de reglas del catálogo. Antes del
refactor, ese segundo ejecutable falla por las firmas pendientes; esto no cuenta
como comprobación exitosa de sus asserts de comportamiento.

`test-frontend` ejecuta el WASM real de AIDA y una variante con un catálogo demasiado
grande. Comprueba el protocolo de buffers, las solicitudes emitidas y sus valores.
Las funciones JavaScript de controles escalares se ejecutan en un contexto aislado
con elementos mínimos; no sustituyen las comprobaciones visuales siguientes.

`test-backend` usa un proceso y puerto propios, sin PostgreSQL. Incluye texto que
necesita escaping, conservación de null al editar otro campo, booleanos
null/false/true y fechas presentes/ausentes.

## Comprobación de navegador después de implementar

Usar frontend y backend de pruebas con procesos y puertos propios. No utilizar la
base de datos del usuario. Verificar tanto la interfaz como el cuerpo HTTP enviado.

1. Crear una materia con comillas, barra invertida y Unicode en la denominación;
   comprobar que GET devuelve exactamente el texto enviado. PK vacía no debe
   emitir POST. Comprobar también una PK compuesta con un componente vacío.
2. Cargar un docente con `esImportador: null`; editar su nombre y guardar. PUT
   conserva null y excluye la PK. Repetir asignando Sí, No y Sin valor.
3. Crear una clase sin fecha; asignar una fecha, guardar y luego vaciarla. Verificar
   las representaciones públicas objeto/null y que otros campos no cambien.
4. Después de un POST exitoso, comprobar que el formulario de alta restablece
   texto/números/fechas opcionales vacíos y booleanos opcionales Sin valor.
5. Servir una copia temporal del frontend sin `widgets.js` para ejercer el control
   genérico de objetos: un objeto opcional null muestra Sin valor, sus hijos quedan
   deshabilitados y guardar otra columna conserva null. Activar, completar,
   guardar y volver a desactivar el objeto debe conservar el resto de la fila.
6. Confirmar que las PK de filas cargadas siguen bloqueadas, los booleanos
   obligatorios siguen siendo checkboxes y las FK conservan sus selectores.
7. Probar un texto que exceda el buffer JSON tras escapar sus caracteres. Mostrar
   el error sin enviar datos parciales; una entrada posterior válida debe funcionar.

## Estado previo fuera de alcance

La suite general tenía cinco fallos por expectativas de PostgreSQL anteriores al
campo `esImportador`: dos en `postgres_ddl_test`, dos en
`aida_schema_reference_test` y uno en `model_consumers_test`. No actualizar esas
referencias, el snapshot aceptado ni las migraciones como parte de este refactor.
