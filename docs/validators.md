# Validadores de entidades concretas

REST ya admite un validador tipado por entidad. El binding automático de las reglas
nombradas en el contrato y su ejecución en WASM siguen pendientes. Son mecanismos
distintos: declarar una entrada en `rules` no registra una función.

## Registro REST implementado

La aplicación publica tipos concretos desde sus definiciones, por ejemplo
`Docente = zigma.Entity(type_defs, docente_def)`. La lógica de negocio recibe ese
tipo; el adaptador REST traduce el resultado al formato de violación público:

```zig
const Context = aida_rest.ValidationContext; // struct { today: aida.Fecha }

const validators = rest.defineBusinessValidators(aida.Model, .{
    .docentes = rest.BusinessValidator(aida.Docente, Context){
        // Adaptador de AIDA: llama a validarDocente(value, context.today)
        // y traduce cada error de dominio a su código y mensaje públicos.
        .validate = aida_rest.business_validators.docentes.validate,
    },
});
const Api = rest.Api(aida.Model, codecs, validators);
```

`BusinessValidator(T, Context)` contiene
`validate: *const fn (T, Context) ?BusinessRuleViolation`.
El registro exige exactamente `BusinessValidator(Model.Row(entity), Context)`:
rechaza una entidad desconocida, otra entidad como entrada, un struct manual de
igual forma o una firma incompatible. Todos los validadores de una API comparten
el mismo tipo de contexto; mezclar tipos distintos también falla al compilar.
Una entidad omitida no tiene validador;
`Api(Model, codecs, .{})` conserva el CRUD sin reglas de negocio.

Los validadores son funciones locales y síncronas. Reciben una fila completa,
incluidos sus opcionales, y el contexto de aplicación. Devuelven null o una
violación con `code` y `message`.
No reciben JSON, celdas de PostgreSQL ni una conexión de base de datos.

## Fecha de referencia y regla de edad

`Api.ValidationContext` expone el tipo compartido. La firma de entrada es
`api.handle(allocator, repository, request, context)`. Para pruebas se pasa un
valor fijo; una API sin validadores usa `void` y recibe `{}` como último argumento.
Los validadores que no requieren contexto también se declaran con `void`.

En AIDA, [validation_context.zig](../examples/aida/src/validation_context.zig)
convierte el reloj real a una fecha civil con **UTC−03:00 fijo**. Es una política
de la aplicación, independiente de la zona horaria del sistema operativo.
`ContextProvider.get()` se llama una vez por solicitud dentro de `std_http.serve`:
no se guarda una fecha al arrancar ni se vuelve a consultar el reloj por cada fila.
La firma del transporte es `serve(io, allocator, api, repository, provider, config)`.
El proveedor es una dependencia de la aplicación y no toma la fecha del cliente.
Si falla, se devuelve 500 sanitizado sin invocar la API; el servidor continúa.
Para contexto `void`, el transporte ofrece `EmptyContextProvider`.

```zig
var provider = aida_rest.ContextProvider{ .io = init.io };
try std_http.serve(init.io, init.gpa, &api, &repository, &provider, .{});

// En un test o llamador sin HTTP:
const context: Api.ValidationContext = .{
    .today = .{ .@"año" = 2026, .mes = 10, .@"día" = 28 },
};
const response = try api.handle(allocator, &repository, request, context);
defer allocator.free(response.body);
```

`validarDocente(Docente, Fecha)` conserva la normalización de `cargo` (espacios y
mayúsculas). Para `teorico`, primero exige cinco años de experiencia y luego fecha
de nacimiento y treinta años cumplidos. Otros cargos pueden omitir el nacimiento.
`Fecha.ageOn(today)` valida ambas fechas, rechaza nacimientos futuros y calcula
años cumplidos, sin dividir segundos por 365. El cumpleaños del 29 de febrero se
considera el 1 de marzo en años no bisiestos.

| Error de negocio | Código REST (422) |
| --- | --- |
| Experiencia ausente o menor que cinco | `teorico_requires_five_years_experience` |
| Nacimiento ausente | `teorico_requires_birth_date` |
| Edad menor que treinta | `teorico_requires_thirty_years` |
| Nacimiento futuro | `birth_date_in_future` |

Una fecha civil inválida enviada por HTTP sigue produciendo 400 desde el codec,
antes de llegar al validador. Los datos inválidos almacenados siguen produciendo
500 al decodificarse. El adaptador también devuelve `invalid_birth_date` si se lo
invoca directamente con una fecha inválida, fuera de esos puntos de conversión.

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
La fila y el contexto se prestan durante la llamada: la función no debe retener
sus referencias.
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
