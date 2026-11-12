# Supermercado

Aplicación independiente de Zigma con frontend WASM, API CRUD PostgreSQL y migraciones
Liquibase para las ocho entidades del MER. Depende de la biblioteca mediante `../..`;
no importa AIDA. Su build y sus pruebas pertenecen al consumidor.

## Estructura y alcance

| Archivo | Responsabilidad |
| --- | --- |
| [src/supermercado.zig](src/supermercado.zig) | Definiciones con campos inline, tipos concretos, registro y `Model`. |
| [src/system.zig](src/system.zig) | Contrato inyectado en el frontend genérico. |
| [src/postgres.zig](src/postgres.zig) | Mappings, snapshot canónico y DDL inicial generados. |
| [src/rest.zig](src/rest.zig) | Codecs y validaciones tipadas de las ocho rutas CRUD, con contexto `void`. |
| [src/instant.zig](src/instant.zig) y [src/instant_wire.zig](src/instant_wire.zig) | Calendario compartido y conversión de TIMESTAMPTZ a UTC. |
| [src/pricing.zig](src/pricing.zig) | Selección temporal y cálculo exacto por renglón. |
| [build/modules.zig](build/modules.zig) | Módulos nativos compartidos por aplicación y pruebas. |
| [build/application.zig](build/application.zig) | Composición de frontend, runtime y migraciones mediante la API pública del framework. |
| [build/tests.zig](build/tests.zig) | Suites propias y rechazos de compilación. |
| [db/](db/) | Snapshot aceptado, changelog y baseline de las ocho tablas; se publica con la app. |

La apertura comercial del carrito, la selección automática de versiones, el subtotal
y la emisión transaccional del ticket quedan para la siguiente etapa. En este CRUD
los estados se validan como valores permitidos; todavía no se comprueban transiciones
ni se impide editar el historial comercial. El total del ticket se ingresa explícitamente.
Las funciones de `pricing.zig` están disponibles, pero el CRUD no las ejecuta automáticamente.

Los importes HTTP y los controles del frontend usan **centavos enteros** (199 equivale
a 1,99 unidades monetarias). Los instantes de entrada usan exclusivamente
`YYYY-MM-DDTHH:mm:ss.SSSZ`; la salida normaliza el formato ISO de PostgreSQL a UTC.
Se rechazan calendarios inválidos y fracciones de milisegundo que perderían precisión.

Los errores de formato devuelven 400. Las reglas por fila devuelven 422: precios y
cantidades positivos, grupos positivos, porcentajes de 1 a 100, estados
`abierto`/`cerrado`/`cancelado`, totales no negativos y descuentos de renglón entre cero
y su importe bruto, sin desbordar `i64`. En PUT se valida la fila completa resultante.
Las violaciones de PK, UK y FK devuelven 409. Las referencias opcionales conservan `null`.
Las reglas numéricas se aplican en REST; el baseline genera claves, tipos y nulabilidad,
pero no agrega `CHECK` SQL para esas reglas de negocio.

## Compilar y ejecutar

Desde `examples/supermercado/`, con la versión de Zig indicada en el manifest:

```sh
zig build frontend      # solo zig-out/frontend/, sin libpq ni servicios
zig build check-schema  # compara el modelo con db/schema.snapshot.json
zig build check -Dlibpq-prefix=/opt/homebrew/opt/libpq
zig build -Dlibpq-prefix=/opt/homebrew/opt/libpq
```

El build por defecto instala `zig-out/frontend/`, `zig-out/bin/supermercado-backend`
y `zig-out/bin/supermercado-launcher`. El backend falla en compilación si el modelo
difiere del snapshot aceptado. El frontend puede compilarse por separado.
En Linux pueden usarse `-Dlibpq-include` y `-Dlibpq-lib` en lugar del prefijo.

Para iniciar, prepará una base PostgreSQL propia y configurá sus conexiones. Por ejemplo,
para una base local llamada `supermercado`, con el usuario y contraseña de tu entorno:

```sh
export DATABASE_URL='postgresql://usuario:clave@127.0.0.1:5432/supermercado'
export LIQUIBASE_URL='jdbc:postgresql://127.0.0.1:5432/supermercado'
export LIQUIBASE_USERNAME='usuario'
export LIQUIBASE_PASSWORD='clave'
export LIQUIBASE_BIN='/ruta/a/liquibase'
zig build run -Dlibpq-prefix=/opt/homebrew/opt/libpq
# Solo API:
zig build run-backend -Dlibpq-prefix=/opt/homebrew/opt/libpq
```

Se requiere Liquibase Community 5.0.4 con Java y el driver PostgreSQL. `run` y
`run-backend` buscan JAR primero en `liquibase_libs/` de la aplicación y luego en el
directorio homónimo de la dependencia. Pasan rutas absolutas y funcionan también al
invocar `zig build --build-file /ruta/al/build.zig` desde otro directorio.
Un `LIQUIBASE_CLASSPATH` explícito tiene prioridad; usá rutas absolutas. También podés
instalar el driver en `lib/` de Liquibase. El lanzador informa las direcciones del
frontend y la API; `FRONTEND_PORT`, `HTTP_ADDRESS` y `HTTP_PORT` permiten cambiarlas.

## Migraciones

El historial inicial ya está incluido. `run` y `run-backend` aplican los changesets
pendientes antes de habilitar HTTP. Para evolucionar el modelo:

```sh
zig build check-schema
zig build migration -Dname=nombre_del_cambio
# Revisar y completar db/drafts/ antes de aceptar.
zig build accept-migration -Dlibpq-prefix=/opt/homebrew/opt/libpq
zig build apply-migrations
```

`accept-migration` verifica el draft en PostgreSQL descartable con Docker y Liquibase.
`apply-migrations` aplica el historial aceptado a la conexión configurada y termina.
Para estos comandos, instalá el driver en Liquibase o definí `LIQUIBASE_CLASSPATH`.
`init-migrations` inicializa un consumidor sin historial a partir del modelo, sin
conectar a PostgreSQL; no es necesario ejecutarlo sobre el historial incluido.

## Pruebas

Todas las descripciones están en español:

| Suite | Casos | Cobertura |
| --- | ---: | --- |
| Modelo, cálculo y proyección PostgreSQL | 27 | Ocho entidades, selección histórica, descuentos y schema. |
| Rechazos de compilación | 4 | Nulabilidad, importes enteros y FK completa. |
| `test/rest_test.zig` | 16 | Rutas, codecs, validadores, PUT y fallos de memoria. |
| `test/integration/frontend_test.mjs` | 6 | WASM real, nulabilidad, claves compuestas y cuerpos PUT. |
| `test/integration/application_test.py` | 10 | Paquete, comandos, historial, backend, drivers y persistencia. |

```sh
zig build test           # 43 pruebas Zig, cuatro rechazos y snapshot; sin servicios
zig build test-model
zig build test-pricing
zig build test-schema
zig build test-rest
zig build test-compile-errors
zig build test-frontend  # Node
zig build test-application # Python y Node; omite los cuatro casos que necesitan libpq
zig build test-local    # reúne las suites anteriores sin servicios
```

`test-application` usa paquetes reales generados con `zig fetch`, en directorios
temporales. Tres casos adicionales prueban el backend con libpq y Liquibase simulado;
el último usa Docker, Liquibase 5.0.4 y PostgreSQL 18.4 descartable. Comprueba arranque,
restricciones, persistencia al reiniciar e idempotencia del baseline. Nunca modifica
el historial del checkout. Para ejecutar los diez casos:

```sh
zig build test-application -- --with-libpq --libpq-prefix=/opt/homebrew/opt/libpq \
  --liquibase=/ruta/a/liquibase --jdbc-classpath=/ruta/al/postgresql.jar
```

## Contrato relacional

Los nombres SQL y del registro `entity_defs` son:

| Entidad | PK | UK adicionales |
| --- | --- | --- |
| `productos` | `id` | — |
| `productos_precios` | `id` | `(id_producto, vigencia_desde)`, `(id_producto, id)` |
| `clientes` | `id` | — |
| `carritos` | `id` | — |
| `productos_carritos` | `(id_carrito, id_producto)` | — |
| `descuentos_cantidad` | `id` | `(id_producto, vigencia_desde)`, `(id_producto, id)` |
| `tickets` | `id` | `id_carrito` |
| `tickets_productos` | `(id_ticket, id_producto)` | — |

Cada entidad se declara con `entityDefinition`, incluyendo sus campos directamente
en `.fields` y sus PK, UK y FK. De esa definición se deriva el tipo concreto con
`Entity` y se registra como `Type + definition`. `Model.Row` devuelve ese tipo;
`system.zig` reexporta `type_defs` y `entity_defs` para los consumidores genéricos.
Un record separado queda para conjuntos de campos reutilizados, como `docente` y
`materia` en la composición de `asignacion` de AIDA.

Solo son opcionales `carritos.id_cliente`, `tickets.id_cliente` y
`productos_carritos.id_descuento`. La descripción del producto queda obligatoria en
esta primera versión. Los importes usan el dominio `importe`: `i64`/`BIGINT`, en centavos.
Los porcentajes son enteros de 1 a 100. El dominio `instante` utiliza strings UTC
canónicos `YYYY-MM-DDTHH:mm:ss.SSSZ` en Zig y `TIMESTAMPTZ` en PostgreSQL.

Las FK de precio y descuento son compuestas: `(id_producto, id_precio)` y
`(id_producto, id_descuento)` apuntan a `(id_producto, id)` de sus respectivas tablas.
Esto impide asociar al renglón condiciones comerciales de otro producto. La referencia
nullable al descuento utiliza la semántica PostgreSQL predeterminada `MATCH SIMPLE`:
un `id_descuento` nulo permite un producto sin promoción.

## Contrato de precios y descuentos

`pricing.zig` recibe el contrato de la aplicación como `@import("contract")` y
expone funciones puras:

- `selectPrice(versions, product_id, opened_at)`: devuelve la última versión de precio
  con vigencia menor o igual a la apertura; falla con `PriceNotFound` si no existe.
- `selectPromotion(versions, product_id, opened_at)`: devuelve la última versión
  aplicable si está activa, o `null`. Una desactivación no revive promociones anteriores.
- `calculateLine(quantity, unit_price, promotion)`: devuelve `bruto`, `descuento` y
  `total` en centavos. Descuenta solamente grupos completos de N unidades y redondea
  el descuento una vez por renglón al centavo más cercano, con mitades hacia arriba.

Las selecciones usan la apertura recibida, nunca el reloj actual ni el orden de las
listas. Las pruebas cubren vigencias inclusivas, productos ajenos, versiones futuras,
desactivación, ausencia de precio/promoción y fechas de apertura inválidas. El cálculo
cubre cantidades crecientes/decrecientes, N=1, 100 %, redondeo, entradas inválidas y
desbordamientos. El subtotal del carrito es derivado; el ticket conserva los valores finales.

Las selecciones validan el instante de apertura y las vigencias del producto consultado:
formato canónico, calendario gregoriano entre los años 0001 y 9999, horas, minutos y
segundos. No consultan el reloj ni modifican las listas. Presuponen que las versiones
respetan la unicidad `(id_producto, vigencia_desde)` declarada en el modelo.
Las filas devueltas conservan referencias a los strings provistos por el llamador.

`calculateLine` rechaza cantidades y precios no positivos, grupos no positivos y
porcentajes fuera de 1 a 100 en promociones activas. Usa intermediarios `i128` y
devuelve `AmountOverflow` si el importe bruto no cabe en `i64`. Estos controles se
ejecutan al llamar a la función; construir una fila Zig no los ejecuta automáticamente.

## Alcance de las comprobaciones

Las pruebas del snapshot y DDL verifican PK, UK, FK, nulabilidad y tipos SQL; no
ejecutan SQL. Los cuatro rechazos de compilación comprueban precio obligatorio,
cantidad obligatoria, prohibición de importes fraccionarios en el tipo entero y rechazo
de una FK de precio que no apunta a una clave completa.

El MER requiere además impedir cambios retroactivos y modificaciones del historial,
restringir estados y transiciones, emitir tickets no vacíos y cerrar el carrito en una
transacción junto con su ticket. La declaración de entidades y las funciones puras no
implementan por sí solas esas operaciones. Las pruebas de servicio y PostgreSQL real
deberán agregarse al implementar esa etapa. Los codecs y el CRUD ya cuentan con pruebas
unitarias y de integración. Tampoco un metadato `rules` genera automáticamente
un `CHECK` SQL ni un validador REST.
