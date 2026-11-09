# Crear una aplicación nueva con Zigma

Zigma permite describir campos, tipos y relaciones una vez y derivar de ese contrato
los tipos Zig, la API CRUD, el catálogo del frontend y la estructura PostgreSQL.
La aplicación aporta su dominio, sus reglas de negocio y la composición de los
adaptadores que necesita.

Los tipos y las implementaciones especializadas se construyen al compilar. Este
recorrido no genera archivos fuente Zig para editar a mano: el contrato se vuelve
a evaluar cuando recompilás la aplicación.

Esta guía construye un **inventario independiente de AIDA**, con una entidad
`Product`, una regla que impide stock negativo y una interfaz web. El primer
recorrido compila el frontend y prueba las reglas del dominio. La sección de
PostgreSQL completa la aplicación ejecutable con una API persistente y un historial
propio de migraciones.

- [Preparar el proyecto](#1-preparar-el-proyecto).
- [Definir el contrato](#2-definir-el-contrato).
- [Proveer el sistema al frontend](#3-proveer-el-sistema-al-frontend).
- [Conectar las reglas con REST](#4-conectar-las-reglas-con-rest).
- [Configurar el build](#5-configurar-el-build).
- [Ejecutar y probar](#6-ejecutar-y-probar).
- [Trabajar con el contrato día a día](#7-trabajar-con-el-contrato-día-a-día).
- [Agregar dominios propios](#8-agregar-dominios-propios).
- [Incorporar PostgreSQL](#9-incorporar-postgresql).
- [Organizar las verificaciones](#10-organizar-las-verificaciones).

## 1. Preparar el proyecto

Usá Zig **`0.17.0-dev.1818+7051f8e73`**, la versión indicada por
[el paquete](../build.zig.zon). Las APIs de reflexión y build de esta guía dependen
de esa versión de desarrollo.

Para empezar con una dependencia local, disponé el checkout de Zigma y tu aplicación
como directorios hermanos:

```text
workspace/
├── zigma-definition/
└── inventario/
    ├── build.zig
    ├── build.zig.zon
    └── src/
        ├── contract.zig
        ├── system.zig
        └── rest.zig
```

Desde `workspace/`, creá el paquete consumidor:

```sh
mkdir inventario
cd inventario
zig init
zig version
```

En el `build.zig.zon` generado, reemplazá el contenido de `dependencies` por:

```zig
.dependencies = .{
    .zigma_definition = .{ .path = "../zigma-definition" },
},
```

Conservá el `name`, el `fingerprint` propio que generó `zig init` y el resto del
manifest. La ruta de la dependencia es relativa al directorio de ese manifest.
Los archivos `src/main.zig` y `src/root.zig` creados por `zig init` no participarán
en este build; podés eliminarlos si no los vas a utilizar.

La dependencia local usa el estado de ese checkout. Para compartir una aplicación
reproducible, acordá una revisión concreta del framework o configurá una dependencia
remota fijada a una revisión, según [la referencia de dependencias](../DOCS.md#usar-como-dependencia).
El número de versión del manifest no garantiza que exista un tag remoto con ese nombre.

Para este primer recorrido necesitás Zig y un navegador; los comandos para servir
archivos estáticos usan Python 3. Las comprobaciones de API usan `curl`. PostgreSQL,
libpq y Liquibase se incorporan al elegir persistencia PostgreSQL.

## 2. Definir el contrato

Creá `src/contract.zig` con este contenido completo:

```zig
const std = @import("std");
const zigma = @import("zigma");

pub const type_defs = zigma.defineTypes(zigma.common_type_defs);

pub const product = zigma.record(type_defs, .{
    .sku = .{ .type = "text", .label = "Código", .nullable = false },
    .name = .{ .type = "text", .label = "Nombre", .nullable = false, .is_name = true },
    .stock = .{ .type = "integer", .label = "Existencias", .nullable = false },
    .active = .{ .type = "boolean", .label = "Activo", .nullable = false },
    .notes = .{ .type = "text", .label = "Notas" },
});

pub const product_def = .{
    .fields = product,
    .pk = .{"sku"},
};

pub const Product = zigma.Entity(type_defs, product_def);

pub const entity_defs = zigma.defineEntities(.{
    .products = .{ .Type = Product, .definition = product_def },
});

pub const Model = zigma.Framework(type_defs, entity_defs);

pub fn validateProduct(value: Product) error{NegativeStock}!void {
    if (value.stock < 0) return error.NegativeStock;
}

test "la fila del modelo es el tipo concreto" {
    try std.testing.expect(Model.Row("products") == Product);
}

test "cero y null son valores válidos distintos" {
    const value: Product = .{
        .sku = "P-001",
        .name = "Cuaderno",
        .stock = 0,
        .active = false,
        .notes = null,
    };
    try validateProduct(value);
    try std.testing.expect(value.notes == null);
}

test "el stock negativo viola la regla" {
    const value: Product = .{
        .sku = "P-001",
        .name = "Cuaderno",
        .stock = -1,
        .active = true,
        .notes = null,
    };
    try std.testing.expectError(error.NegativeStock, validateProduct(value));
}
```

Las piezas se construyen en este orden:

| Pieza | Responsabilidad en el inventario |
| --- | --- |
| `type_defs` | Asocia dominios con tipos Zig: `text` → `[]const u8`, `integer` → `i64`, `boolean` → `bool`. |
| `product` | Describe los campos y su nulabilidad; es un record reutilizable. |
| `product_def` | Agrega la PK y, cuando corresponda, UK, FK y metadatos de reglas. |
| `Product` | Es el struct de datos generado, utilizable en funciones, variables y colecciones. |
| `entity_defs` | Asocia `products`, nombre de tabla y ruta, con el tipo y su definición. |
| `Model` | Reúne la interpretación normalizada y permite que los consumidores la compartan. |

`Product` tiene `sku: []const u8`, `name: []const u8`, `stock: i64`,
`active: bool` y `notes: ?[]const u8`. No se escribe otro struct con esos campos.
`Model.Row("products")` devuelve exactamente `Product`.

`Model.info.products` contiene los metadatos normalizados de esa entidad, con
defaults y restricciones explícitos. Los generadores los consumen sin volver a
interpretar el record. Esos metadatos pueden serializarse; no contienen tipos Zig
ni implementaciones de funciones.

El default de `nullable` es `true`; por eso `notes` admite null. Los campos de PK
siempre son obligatorios en la entidad, aun si su record admite null. Los dominios
se declaran sin `?`: la opcionalidad pertenece a cada campo.

Una fila completa **no tiene defaults implícitos**. Un literal Zig debe proporcionar
todos sus campos, incluyendo `.notes = null`. En HTTP, el parser de POST sí completa
con null los campos nullable omitidos. Son dos puntos de entrada distintos.

`validateProduct` expresa una regla sobre valores reales de `Product`. Declarar la
función no la ejecuta automáticamente al crear un literal: el llamador debe invocarla.
En el paso 4 se conectará con las escrituras REST.

## 3. Proveer el sistema al frontend

Creá `src/system.zig`:

```zig
// addAppFromDep inyecta nuestro contrato bajo el nombre de import "contract".
const contract = @import("contract");

pub const type_defs = contract.type_defs;
pub const entity_defs = contract.entity_defs;
```

El frontend espera un módulo con `type_defs` y `entity_defs`. El helper de build
recibe el archivo del dominio mediante `contract_root` y lo inyecta como
`@import("contract")` en `system_root`. El nombre del import identifica la función
del módulo y no depende del nombre de la aplicación.

Si se omite `contract_root`, el helper usa `system_root` como raíz del contrato.
También podés pasar directamente `src/contract.zig` como `system_root`, ya que
publica ambas colecciones. Esta guía conserva el adaptador para mostrar cómo
separar el dominio del punto de entrada del frontend.

Los datos iniciales de una aplicación persistente se incorporan mediante su
historial SQL o la API. El frontend deriva el catálogo del contrato y consulta
las filas al servidor.

## 4. Conectar las reglas con REST

Creá `src/rest.zig`:

```zig
const rest = @import("zigma_rest");
const contract = @import("contract");

pub const codecs = rest.defineCodecs(contract.type_defs, rest.common_codecs);

fn validateProductBusinessRules(value: contract.Product, _: void) ?rest.BusinessRuleViolation {
    contract.validateProduct(value) catch |err| switch (err) {
        error.NegativeStock => return .{
            .code = "stock_must_be_nonnegative",
            .message = "El stock no puede ser negativo",
        },
    };
    return null;
}

pub const validators = rest.defineBusinessValidators(contract.Model, .{
    .products = rest.BusinessValidator(contract.Product, void){
        .validate = validateProductBusinessRules,
    },
});

pub const Api = rest.Api(contract.Model, codecs, validators);
```

Los codecs describen la conversión entre HTTP/JSON y las celdas textuales del
repositorio. Los tres dominios incorporados ya tienen codecs. `defineCodecs`
comprueba que el registro cubra los dominios del contrato.

El adaptador de negocio recibe un `Product`, llama a la función del dominio y
traduce su error a un código y un mensaje públicos. REST construye la entidad
con sus tipos Zig antes de invocar el callback; no hace falta buscar columnas
ni convertir `stock` manualmente.

El segundo parámetro es `void` porque esta regla no necesita datos externos.
Cuando una regla necesita el día actual u otro dato de runtime, se define un
contexto común para la API y un proveedor que lo obtiene una vez por solicitud.
Ese mecanismo se explica en [validadores REST](validators.md).

Para una aplicación sin reglas de negocio, el registro puede ser `.{}`:
`rest.Api(contract.Model, codecs, .{})`. En cambio, declarar `rules` dentro de una
definición de entidad solo registra metadatos y valida sus dependencias; todavía
no conecta ni ejecuta funciones. El registro REST anterior es lo que activa la regla.

## 5. Configurar el build

Reemplazá `build.zig` por:

```zig
const std = @import("std");
const zigma_build = @import("zigma_definition");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const dep = b.dependency("zigma_definition", .{
        .target = target,
        .optimize = optimize,
    });

    _ = zigma_build.addAppFromDep(b, dep, .{
        .system_root = b.path("src/system.zig"),
        .contract_root = b.path("src/contract.zig"),
        .title = "Inventario",
    });

    const domain_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/contract.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigma", .module = dep.module("zigma") }},
        }),
    });
    const run_tests = b.addRunArtifact(domain_tests);
    b.step("test", "Probar el contrato y las reglas del inventario").dependOn(&run_tests.step);
}
```

`addAppFromDep` compila el frontend para `wasm32-freestanding` con optimización
`.small`, instala sus archivos y publica `frontend`. No recibe opciones de target
nativo ni adaptador REST. Las opciones `target` y `optimize` del build anterior
se usan para las pruebas del dominio y, más adelante, para el servidor.

El paso `test` lo define este proyecto: ejecuta los tests incluidos en
`contract.zig`. Los comandos `test-frontend` y `test-local` del repositorio
Zigma/AIDA no se agregan automáticamente a tu aplicación. `rest.zig` se conectará
al backend mediante `addRuntimeFromDep` en la sección de PostgreSQL.

Si solo necesitás tipos y validaciones Zig, podés usar `dep.module("zigma")` en
un módulo propio y omitir `addAppFromDep`. JSON, REST y PostgreSQL son componentes
que se incorporan según la aplicación.

## 6. Ejecutar y probar

Todos los comandos de esta sección se ejecutan desde `inventario/`.

```sh
zig build test
zig build
```

El primer comando ejecuta las tres pruebas del dominio. El segundo instala:

```text
zig-out/
└── frontend/
    ├── frontend.wasm
    ├── index.html
    ├── main.js
    ├── api-config.js
    └── title.js
```

Podés servir la interfaz para revisar el catálogo y los controles:

```sh
python3 -m http.server 8000 --bind 127.0.0.1 --directory zig-out/frontend
```

Abrí `http://127.0.0.1:8000`. La tabla y los controles se construyen desde el catálogo
incluido en WASM. El catálogo conserva el dominio, su forma de datos y la nulabilidad
efectiva de cada campo. Para consultar o modificar filas, completá
[la composición con PostgreSQL](#9-incorporar-postgresql) e iniciá su API. Las reglas
de negocio se comprueban en el servidor al recibir cada solicitud.

La página usa por defecto `http://localhost:8080/api`. Si cambiás `HTTP_PORT`,
configurá también `globalThis.ZIGMA_API_BASE` en el `api-config.js` que servís.
Para una prueba local podés editar `zig-out/frontend/api-config.js`; esa modificación
se pierde al reinstalar el frontend. Una configuración permanente debe formar parte
del build o del servidor de archivos de tu aplicación. El helper no lee `.env` por
sí mismo; los valores del backend deben estar exportados en el ambiente del proceso.

## 7. Trabajar con el contrato día a día

### Agregar o modificar un campo

Por ejemplo, para incorporar un código de barras opcional, agregá al record `product`:

```zig
.barcode = .{ .type = "text", .label = "Código de barras" },
```

Al recompilar, `Product` incorpora `barcode: ?[]const u8`, REST reconoce ese campo
y el catálogo del frontend publica el nuevo control. Actualizá los literales
completos de tus tests y tu lógica de aplicación con `.barcode = null` o un valor.
No agregues manualmente otra lista de campos en el controlador o la interfaz.

Ejecutá `zig build test`, prepará y aceptá la migración PostgreSQL, y recompilá
con `zig build`. Reiniciá el backend para aplicar el historial aceptado y recargá
la página. Recompilar por sí solo no modifica la base.

| Cambio | Trabajo de la aplicación |
| --- | --- |
| Nombre, tipo o nulabilidad de un campo | Cambiar el contrato, adaptar los consumidores que marque el compilador y verificar HTTP; revisar la migración PostgreSQL. |
| Label o descripción | Cambiar los metadatos y reconstruir el frontend; no altera la estructura PostgreSQL. |
| Regla de negocio | Modificar la función y sus tests; registrar el adaptador si todavía no existe. |
| Nueva entidad | Definir su record, definición y tipo; agregarla a `entity_defs` y registrar su validador si corresponde. |
| Nuevo dominio | Definir su tipo Zig, codec REST, mapping SQL y, si hace falta, widget. |

### Elegir el tipo adecuado

| Necesidad | Tipo |
| --- | --- |
| Lógica de negocio o colección de filas completas | `Product` o `Model.Row("products")`, que son idénticos. |
| Instancia de un record sin restricciones de entidad | `zigma.RecordInstanceType(type_defs, product)`. |
| Expresar una modificación parcial en código propio | `Model.Patch("products")`: excluye PK y distingue omisión de asignación. |
| Expresar filtros de igualdad en código propio | `Model.Filters("products")`: null significa ausencia del filtro. |

Por ejemplo, dentro de un módulo que importe `contract`:

```zig
const patch: contract.Model.Patch("products") = .{
    .notes = .{ .set = null },
    .stock = .{ .set = 5 },
};
const filters: contract.Model.Filters("products") = .{ .sku = "P-001" };
```

Los demás campos del patch quedan en `unset`; el filtro no representa `IS NULL`.
Estos tipos están disponibles para código de aplicación, pero los métodos del
repositorio actual todavía reciben celdas textuales: no aceptan directamente
`patch` y `filters`. Los cuerpos JSON y la query del apartado anterior ya son
interpretados por REST.

### Agregar relaciones

Una FK se declara en la definición de la entidad que contiene el campo origen.
Por ejemplo, después de agregar `category_id` al record y registrar una entidad
`categories` con PK `id`:

```zig
.fks = .{
    .category = .{
        .entity = "categories",
        .fields = .{ .category_id = "id" },
    },
},
```

`defineEntities` comprueba que el destino exista y que sus campos referenciados
formen una PK o UK completa. El modelo admite relaciones reflexivas y circulares;
el generador DDL actual rechaza determinados ciclos entre tablas. Verificá las
relaciones con las pruebas PostgreSQL de tu aplicación.

Podés separar un contrato grande en varios archivos de dominio y mantener un
módulo raíz que los reúna. La fuente de verdad sigue siendo única si los
consumidores derivan sus tipos y metadatos desde esa composición.

## 8. Agregar dominios propios

Un dominio nuevo se agrega a `type_defs` con `zigma.TypeDef{ .Type = T }`, combinando
la colección con `zigma.merge`. `T` describe el valor presente; la nulabilidad
sigue en los campos que lo usan.

Cada adaptador decide cómo representa ese dominio:

| Componente | Qué agregar |
| --- | --- |
| Dominio | El tipo Zig y sus operaciones de validación/conversión, independientes de HTTP. |
| REST | Un `rest.Codec` con `queryToPostgres`, `jsonToPostgres` y `postgresToJson`. Extender `rest.common_codecs` y validar el registro con `defineCodecs`. |
| PostgreSQL | Un `ddl.TypeMapping` con el tipo SQL, separado del contrato. |
| Frontend | Un widget si los controles derivados de la forma Zig no alcanzan; se instala con `.widgets_js = b.path("src/widgets.js")`. |

Los codecs reciben valores no-null. Deben distinguir `InvalidValue` de
`OutOfMemory`; REST administra null y la memoria de la solicitud. Hoy esos codecs
conectan JSON/query con los valores textuales que intercambia el repositorio.
No son todavía familias de codecs parametrizadas por `T`.

[Fecha y sus codecs](../DOCS.md#validación-civil-de-fecha) muestran un dominio
estructurado con validación compartida. Agregar un método de validación no lo
invoca automáticamente en un literal Zig ni en WASM: cada punto de conversión debe
llamarlo. En particular, el frontend genérico no ejecuta los validadores REST de
negocio localmente.

## 9. Incorporar PostgreSQL

El contrato y la API anteriores pueden reutilizarse con PostgreSQL. El paso
adicional es componer la persistencia y el servidor de tu aplicación.
`addAppFromDep` genera el frontend. El helper independiente
`addMigrationsFromDep` agrega el workflow de migraciones y `addRuntimeFromDep`
compone el servidor PostgreSQL y el lanzador compartidos. Tu aplicación conserva
el contrato, sus adaptadores y su historial; no necesita entradas `main.zig` ni
`server.zig` propias.

### Derivar el schema del contrato

Un módulo propio `src/postgres.zig` puede contener:

```zig
const contract = @import("contract");
const ddl = @import("zigma_postgres_ddl");
const migrations = @import("zigma_postgres_migrations");

pub const type_mappings = ddl.common_type_mappings;
pub const baseline_ddl = ddl.createBaselineDdl(contract.Model, type_mappings);
pub const schema_snapshot = migrations.createSchemaSnapshot(contract.Model, type_mappings);
```

Su build debe inyectar `contract` apuntando al contrato del inventario y los módulos
obtenidos con `dep.module("zigma_postgres_ddl")` y
`dep.module("zigma_postgres_migrations")`. Las dos constantes son bytes calculados
en compilación: la herramienta de la aplicación debe escribirlos a archivos si
necesita exportarlos. Estas funciones no crean tablas ni acceden al filesystem.

Los mappings comunes son `TEXT`, `BIGINT` y `BOOLEAN`. Un dominio propio requiere
su mapping adicional. El snapshot describe estructura PostgreSQL; labels y
metadatos de reglas no se convierten en migraciones.

### Mantener un historial propio

El inventario necesita su propio directorio `db/`, baseline, snapshot aceptado y
changelog. El ejemplo conserva el suyo en `examples/aida/db/`.
**El historial de AIDA describe las tablas de AIDA y no se reutiliza
como historial del inventario.**

El flujo para una aplicación que adopta el versionado es:

1. Generar el baseline y snapshot iniciales desde su `Model` y mappings, y versionarlos.
2. Ante un cambio del contrato, comparar el nuevo snapshot con el aceptado y crear un draft.
3. Revisar el SQL, resolver operaciones que requieren intervención y probar el historial
   más el draft en una base descartable. Comparar el catálogo resultante con el esperado.
4. Aceptar el changeset y el nuevo snapshot en el repositorio de la aplicación.
5. Aplicar ese historial aceptado en cada ambiente con Liquibase antes de servir tráfico.

Para registrar los comandos, agregá lo siguiente dentro del `build` anterior, usando
su `dep`, `target` y `optimize`. Este mismo módulo `contract` se compartirá después
con REST y con el servidor PostgreSQL:

```zig
const contract = b.createModule(.{
    .root_source_file = b.path("src/contract.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{.{ .name = "zigma", .module = dep.module("zigma") }},
});
const postgres = b.createModule(.{
    .root_source_file = b.path("src/postgres.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "contract", .module = contract },
        .{ .name = "zigma_postgres_ddl", .module = dep.module("zigma_postgres_ddl") },
        .{ .name = "zigma_postgres_migrations", .module = dep.module("zigma_postgres_migrations") },
    },
});
const migrations = zigma_build.addMigrationsFromDep(b, dep, .{
    .application_postgres = postgres,
    .target = target,
    .optimize = optimize,
    .liquibase_bin = b.option([]const u8, "liquibase-bin", "Ruta al CLI de Liquibase") orelse "liquibase",
});
b.default_step.dependOn(&migrations.schema_guard.step);
```

El contrato `application_postgres` exige solamente `schema_snapshot` y `baseline_ddl`,
ambos strings disponibles en compilación. `Model` y los mappings pueden ser privados.
Las herramientas del framework se compilan con ese módulo inyectado; no hay que copiarlas
ni importar AIDA. `project_root` es opcional y señala el directorio que contiene `db/`;
por defecto se usa la raíz de tu paquete. Agregá `db` a `.paths` si publicás su historial.

En un paquete sin historial ejecutá primero:

```sh
zig build init-migrations
zig build check-schema
zig build
```

`init-migrations` crea los directorios, el baseline y el snapshot. El guard solo se
compila al pedir un artefacto protegido, de modo que no impide esa inicialización.
Después de editar el contrato, `zig build migration` genera el draft aunque el guard
esté en rojo. `zig build accept-migration` reproduce y valida el cambio con Docker,
Liquibase y libpq antes de actualizar los archivos. `zig build apply-migrations` aplica
el historial aceptado usando las variables `LIQUIBASE_*`; no requiere libpq.
Liquibase necesita el driver JDBC PostgreSQL. Si lo instalaste en `liquibase_libs/`
de otro directorio, exportá `LIQUIBASE_CLASSPATH` con la ruta absoluta al JAR o
instalalo en `lib/` de Liquibase para que esté disponible desde tu `project_root`.

Para que `accept-migration -Dlibpq-prefix=...` llegue a la dependencia, ampliá la
creación de `dep` del build anterior:

```zig
const dep = b.dependency("zigma_definition", .{
    .target = target,
    .optimize = optimize,
    .@"libpq-prefix" = b.option([]const u8, "libpq-prefix", "Prefijo de libpq"),
});
```

El helper devuelve los artefactos `migration_tool`, `schema_guard`, `schema_check`,
`schema_validator` y `migration_applier` para integrarlos con tus propios pasos.
`addMigrations` ofrece la composición de bajo nivel con módulos ya creados; AIDA
lo utiliza en [build/aida.zig](../build/aida.zig).

Aceptar una migración actualiza el historial del proyecto. Aplicarla modifica la
base de un ambiente. Reejecutar DDL de creación no reemplaza ese flujo. Si ya usás
Liquibase, conservá tu historial y conectá la comprobación del schema al adoptar
Zigma; no inicialices un baseline nuevo sobre una base existente como si estuviera vacía.

### Componer el servidor y el lanzador

En la llamada inicial a `addAppFromDep`, reemplazá `_ =` por `const app =` para
conservar su resultado. Después del bloque de migraciones, agregá:

```zig
const application_rest = b.createModule(.{
    .root_source_file = b.path("src/rest.zig"),
    .target = target,
    .optimize = optimize,
    .imports = &.{
        .{ .name = "contract", .module = contract },
        .{ .name = "zigma_rest", .module = dep.module("zigma_rest") },
    },
});
const runtime = zigma_build.addRuntimeFromDep(b, dep, .{
    .name = "inventory",
    .contract = contract,
    .application_rest = application_rest,
    .schema_guard = migrations.schema_guard.root_module,
    .frontend_directory = app.frontend_directory,
    .frontend_step = app.frontend_step,
    .target = target,
    .optimize = optimize,
});
b.step("run", "Iniciar PostgreSQL y frontend").dependOn(&runtime.run.step);
b.step("run-backend", "Iniciar solo el backend PostgreSQL").dependOn(&runtime.run_backend.step);
b.step("check-backend", "Compilar sin iniciar servicios").dependOn(&runtime.backend.step);
```

`contract` publica `Model`; `application_rest` publica `Api`. Si
`Api.ValidationContext` es `void`, como en este inventario, el servidor usa
`std_http.EmptyContextProvider`. Si tu API necesita contexto, `rest.zig` debe
publicar también un `ContextProvider` inicializable con `.io`, cuyo `get()`
devuelve el contexto o un error. AIDA tiene un ejemplo para la fecha actual.
Compartí la misma instancia de `contract` entre REST, PostgreSQL y el servidor;
el frontend de `addAppFromDep` conserva su propio grafo WASM.

`project_root` es opcional y por defecto es la raíz del consumidor. Si lo
configurás, usá el mismo directorio que en `addMigrationsFromDep`: allí se busca
`db/changelog-root.yaml`. Los paths de frontend se resuelven por separado, y el
paso `frontend_step` garantiza que sus archivos estén preparados antes de `run`.
El helper devuelve `backend`, `launcher`, `run_backend` y `run`; no registra
comandos ni instala esos binarios automáticamente. Si necesitás distribuirlos,
podés usar `b.installArtifact(runtime.backend)` y `b.installArtifact(runtime.launcher)`.

Con una base disponible, el historial inicializado y las opciones de libpq
reenviadas a la dependencia como en el bloque anterior:

```sh
export DATABASE_URL='postgresql://postgres:postgres@localhost:5432/inventory'
export LIQUIBASE_URL='jdbc:postgresql://localhost:5432/inventory'
export LIQUIBASE_USERNAME=postgres
export LIQUIBASE_PASSWORD=postgres
export LIQUIBASE_BIN=/ruta/a/liquibase
zig build run -Dlibpq-prefix=/opt/homebrew/opt/libpq
# O bien: zig build run-backend -Dlibpq-prefix=/opt/homebrew/opt/libpq
```

La compilación del backend comprueba el snapshot aceptado. El
[servidor compartido](../src/server.zig) aplica el historial con Liquibase,
abre la conexión libpq, selecciona `LIQUIBASE_SCHEMA` (default `public`) y empieza
a atender HTTP. Si una migración falla, el arranque termina antes de conectar
el repositorio. Los datos iniciales pueden formar parte de changesets SQL propios.

El [lanzador compartido](../src/runtime/launcher.zig) recibe las rutas del binario
backend y de los archivos estáticos, espera la API y sirve la página. Configura
la URL de la API automáticamente mediante `/api-config.js` y detiene ambos
procesos con Ctrl+C en macOS/Linux. `HTTP_ADDRESS` y `HTTP_PORT` configuran la API
(default `127.0.0.1:8080`); `FRONTEND_PORT`, la página (default `8000`);
`ZIGMA_STARTUP_TIMEOUT`, la espera inicial en segundos (default `120`).

`run-backend` usa la misma entrada PostgreSQL sin construir ni servir el frontend.
También podés servir los archivos con otro servidor y configurar `ZIGMA_API_BASE`.
Compilar solo `runtime.launcher` no necesita libpq ni un snapshot aceptado.
Las fuentes compartidas y los helpers de build forman parte del paquete publicado.

Con la API iniciada, podés comprobar estos flujos desde otra terminal:

### Consultar y crear

```sh
curl -sS 'http://127.0.0.1:8080/api/products'

curl -i -X POST 'http://127.0.0.1:8080/api/products' \
  -H 'Content-Type: application/json' \
  -d '{"sku":"P-002","name":"Lápiz","stock":20,"active":true}'
```

GET devuelve un array vacío al iniciar una base nueva. POST devuelve `201` y una fila
con `notes: null`. La PK debe enviarse: este contrato no declara IDs autogenerados.

### Editar y comprobar la regla

```sh
curl -i -X PUT 'http://127.0.0.1:8080/api/products?sku=P-002' \
  -H 'Content-Type: application/json' \
  -d '{"stock":0,"active":false,"notes":null}'

curl -i -X PUT 'http://127.0.0.1:8080/api/products?sku=P-002' \
  -H 'Content-Type: application/json' \
  -d '{"stock":-1}'
```

El primer PUT devuelve `200` y un array con la fila actualizada; conserva `name`
porque no se envió. El segundo devuelve `422`:

```json
{"error":{"code":"stock_must_be_nonnegative","message":"El stock no puede ser negativo"}}
```

El stock sigue siendo cero. Para validar PUT, REST selecciona las filas, combina
los cambios con cada estado actual y valida todos los resultados antes de solicitar
la actualización. El frontend muestra el mensaje y el código de un rechazo de negocio.

### Filtrar y eliminar

```sh
curl -sS 'http://127.0.0.1:8080/api/products?active=false'

curl -i -X DELETE 'http://127.0.0.1:8080/api/products?sku=P-002'
```

Los filtros usan igualdad; varios se combinan con AND. PUT y DELETE exigen al
menos uno y pueden afectar varias filas. La ruta es `/api/products?sku=...`;
no existe una variante generada `/api/products/P-002`. PUT no permite modificar PK.

| Resultado | Estado HTTP |
| --- | --- |
| GET, PUT o DELETE correctos | `200`; array de filas. |
| POST correcto | `201`; fila creada. |
| Entrada incompatible con campos, tipos o nulabilidad | `400`. |
| Regla de negocio rechazada | `422`; `error.code` y `error.message`. |
| Conflicto de persistencia, por ejemplo PK duplicada | `409`. |

El formulario deja vacíos los opcionales y conserva null al editar. El checkbox
obligatorio de `active` representa `true` o `false`; un booleano nullable usaría
«Sin valor / Sí / No». Texto vacío en un control nullable se interpreta como null,
aunque REST puede recibir `""` directamente como texto. `0`, `false`, null y el
texto `"null"` son valores distintos.

Los datos persisten en PostgreSQL al detener y volver a iniciar el backend. Las
restricciones PK, UK y FK se aplican en la base, además de las validaciones REST.


## 10. Organizar las verificaciones

En la plantilla, `zig build test` cubre identidad del tipo y casos de la regla;
`zig build` instala el frontend; `zig build check-backend` comprueba la composición
del servidor y su snapshot sin iniciarlo. Al agregar
funcionalidades, extendé las pruebas de tu aplicación:

- **Contrato y negocio:** tipos, nulabilidad, límites y casos de rechazo de cada regla.
- **API:** estados HTTP, códigos/mensajes, POST y PUT; verificar que un rechazo no escriba.
- **Frontend:** catálogo, construcción de solicitudes, opcionales y edición sin perder valores.
- **PostgreSQL:** claves y relaciones reales, migraciones, idempotencia y persistencia.

Las suites de Zigma verifican el framework con sus contratos de prueba. No reemplazan
los casos del inventario. Los scripts de integración de AIDA también contienen
entidades y expectativas de AIDA; usalos como referencia para escribir pruebas de
las rutas de tu aplicación.

El servidor HTTP de referencia es secuencial y el adaptador libpq es bloqueante.
Autenticación, autorización, TLS, paginación y pooling requieren composición o
desarrollo adicional. Además, la validación previa de PUT y su escritura son pasos
separados: una regla que dependa de atomicidad entre operaciones concurrentes requiere
una estrategia de persistencia adicional.

### Referencias para continuar

- [Vocabulario del núcleo](zigma.md): dominios, records, entidades y modelo.
- [Validadores REST](validators.md): tipos concretos, contexto y errores de negocio.
- [Frontend](frontend.md): catálogo, controles, widgets y protocolo WASM.
- [Build](build.md): módulos, artefactos y dependencia entre tareas.
- [Referencia general](../DOCS.md): APIs REST, PostgreSQL y migraciones.
