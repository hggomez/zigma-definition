# Validadores de entidades concretas

REST ya admite un validador tipado por entidad. El binding automático de las reglas
nombradas en el contrato y su ejecución en WASM siguen pendientes. Son mecanismos
distintos: declarar una entrada en `rules` no registra una función.

## Registro REST implementado

La aplicación publica tipos concretos desde sus definiciones, por ejemplo
`Docente = zigma.Entity(type_defs, docente_def)`. La lógica de negocio recibe ese
tipo; el adaptador REST traduce el resultado al formato de violación público:

```zig
fn validateDocenteBusinessRules(value: aida.Docente) ?rest.BusinessRuleViolation {
    aida.validarDocente(value) catch return .{
        .code = "teorico_requires_five_years_experience",
        .message = "A docente with cargo 'teorico' requires at least 5 years of experiencia",
    };
    return null;
}

const validators = rest.defineBusinessValidators(aida.Model, .{
    .docentes = rest.BusinessValidator(aida.Docente){
        .validate = validateDocenteBusinessRules,
    },
});
const Api = rest.Api(aida.Model, codecs, validators);
```

`BusinessValidator(T)` contiene `validate: *const fn (T) ?BusinessRuleViolation`.
El registro exige exactamente el tipo `BusinessValidator(Model.Row(entity))`:
rechaza una entidad desconocida, otra entidad como entrada, un struct manual de
igual forma o una firma incompatible. Una entidad omitida no tiene validador;
`Api(Model, codecs, .{})` conserva el CRUD sin reglas de negocio.

Los validadores son funciones locales y síncronas. Reciben una fila completa,
incluidos sus opcionales, y devuelven null o una violación con `code` y `message`.
No reciben JSON, celdas de PostgreSQL ni una conexión de base de datos.

## Conversión y ejecución

La frontera del repositorio sigue siendo textual. REST completa el estado y
reutiliza `postgresToJson` de cada dominio para formar un `std.json.Value` en
memoria. `std.json.parseFromValueLeaky` materializa `Model.Row(entity)`, que es el
mismo tipo concreto registrado. No se serializa un documento JSON intermedio.
SQL NULL se maneja fuera de los codecs; el texto `"null"` conserva su significado.
`Fecha` mantiene su representación JSON como objeto y su almacenamiento ISO.

| Operación | Comportamiento |
| --- | --- |
| POST | Completa nullable omitidos con null, construye la entidad, valida e inserta. |
| PUT | Selecciona las filas actuales, combina los campos enviados con cada fila, valida todos los resultados y después actualiza. |
| GET y DELETE | No ejecutan validadores de negocio. |
| Entidad sin validador | No agrega conversión para validación ni SELECT preparatorio de PUT. |

Una violación devuelve HTTP 422 y evita la escritura. Un resultado de repositorio
malformado o una conversión incompatible produce un HTTP 500 sanitizado.
`OutOfMemory` de la conversión se propaga. La arena de solicitud conserva las
reservas temporales y los resultados del repositorio se liberan también en errores.
La fila se presta durante la llamada: la función no debe retener sus referencias.
Los mensajes pueden ser literales estáticos; el callback no recibe un allocator.

La secuencia SELECT → validación → UPDATE conserva su comportamiento actual y no
agrega garantías transaccionales frente a escrituras concurrentes.

## Reglas descriptivas y tipos de datos

`Entity` valida definiciones con `fields`, `pk`, `fks`, `uks` y `rules`. Cada regla
puede declarar dependencias serializables, por ejemplo:

```zig
.rules = .{
    .docente_experience = .{ .fields = .{ "cargo", "experiencia" } },
},
```

El núcleo comprueba los nombres de campos y las dependencias repetidas. Conserva
el orden en `Model.info`, sin funciones ni tipos Zig dentro de los metadatos.
Estas reglas no se incluyen en DDL ni snapshots PostgreSQL: modificarlas no crea
una migración. Actualmente no se relacionan automáticamente con el registro REST.

El registro `.Type` + `.definition` asocia entidades concretas con sus definiciones;
no asocia implementaciones de reglas. Los seeds y literales Zig tampoco ejecutan
validación automáticamente. `Entity` y `RecordInstanceType` generan tipos de datos;
el consumidor decide cuándo llamar a una función de negocio.

## Integraciones futuras

Un binding por nombre podría exigir una implementación para cada regla declarada y
comprobar su firma en compilación. La ejecución en WASM podría reutilizar funciones
locales después de construir una fila tipada. Ninguno de esos mecanismos está
implementado: `system.validators` no es parte del contrato actual del frontend.

Las reglas compartibles son las que dependen de una sola fila, como rangos o
combinaciones de campos. Unicidad y existencia de FK dependen del almacenamiento y
siguen siendo responsabilidad de la base de datos. Los widgets pertenecen a los
dominios de la interfaz y no sustituyen validadores de entidades.
