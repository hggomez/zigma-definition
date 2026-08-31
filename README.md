# zigma-definition

system-definition all in zig

Capa descriptiva para sistemas diseñados alrededor de una única fuente de verdad (SSOT).
Port a Zig de [system-definition](https://github.com/ari-dc-uba-ar/system-definition)
(TypeScript).

## Objetivo

Este módulo provee el vocabulario para describir un sistema — tipos de dominio, entidades,
campos, claves primarias, claves únicas, claves foráneas — como valores comptime fuertemente
tipados y serializables. A partir de esas descripciones, generadores de código o
implementaciones on-the-fly pueden derivar los scripts de creación de tablas, los endpoints
CRUD con su capa de base de datos, las pantallas del frontend, los serializadores en ambos
sentidos, los validadores de tipo, etc.

Este módulo cubre solo la parte descriptiva de los sistemas: no genera nada por sí mismo.

El paquete también incluye el módulo independiente `zigma_postgres_ddl`, que consume esas
descripciones y genera las sentencias PostgreSQL de creación inicial del schema. No forma
parte del núcleo descriptivo y requiere un mapping explícito de tipos de dominio a tipos SQL.
Los módulos opcionales `zigma_postgres_executor` y `zigma_postgres_libpq` permiten ejecutar
ese DDL en una transacción sin acoplar el generador a una conexión concreta.

Para schemas versionados, `zigma_postgres_migrations` deriva un snapshot canónico y drafts
de migración desde las mismas entidades, mientras `zigma_liquibase_runner` aplica únicamente
changesets ya aceptados mediante Liquibase. La compilación nunca se conecta a PostgreSQL.

La capa REST opcional mantiene la misma separación: `zigma_rest` genera controllers y
routing en compilación, `zigma_postgres_crud` genera SQL parametrizado y `zigma_std_http`
aporta un servidor secuencial de referencia. Ninguna de esas responsabilidades modifica el
modelo descriptivo ni el snapshot de migraciones.

## Convención de nombres: Def e Info

Cada concepto descriptivo tiene (al menos) dos versiones, distinguidas por sufijo:

* `XxxDef` (definition): lo que escribe el humano. Es un struct literal anónimo con solo lo
  mínimo con sentido semántico; lo que tiene un default razonable se puede omitir.
* `XxxInfo`: lo que produce el framework al completar la `Def` con los defaults. Ahí está
  todo explícito; es lo que consumen los generadores.

La `Info` se deriva determinísticamente de la `Def` con funciones comptime (`completeRecord`,
`completeEntity`), y ambas son serializables (representables como datos planos, sin funciones
embebidas: los comportamientos especiales se referencian por nombre).

## Vocabulario

### Tipos de dominio: `TypeDef`

Cada sistema define su propia colección de tipos, asociando un nombre de tipo (por ejemplo
`"text"`, `"legajo"`) con el tipo Zig que le corresponde en tiempo de ejecución
(`zigma.TypeDef{ .Type = i64 }`). El framework aporta unos pocos tipos comunes en
`zigma.common_type_defs` (`text`, `integer`, `boolean`) como punto de partida; cada sistema
puede agregar los suyos (en el ejemplo, `fecha` y `email`) combinándolos con `zigma.merge`.
`defineTypes(.{...})` valida la colección en el punto de declaración.

### Campos: `FieldDef` / `FieldInfo`

Un campo se describe con un struct literal: el `type` (el nombre de un tipo de la colección)
y, opcionalmente, `label`, `nullable`, `is_name` y `description`. `zigma.record(type_defs, .{...})`
es el `satisfies` del framework: valida el record contra la colección de tipos y lo devuelve
sin cambios, preservando su tipo literal exacto. `completeRecord` produce el `FieldInfo`
correspondiente a cada campo, con esas propiedades siempre presentes (defaults: `label`
derivado del nombre reemplazando `_` por espacio, `nullable: true`, `is_name: false`,
`description: ""`).

### Records: `RecordDef` / `RecordInfo`

Un record es simplemente un struct de campos: la descripción de una fila. `RecordInfoOf`
calcula el tipo exacto de `Info` que corresponde a un record concreto — conserva los nombres
y los literales de `type` de cada campo — y es el tipo que devuelve `completeRecord`.

`RecordInstanceType(type_defs, rec)` deduce, a partir de un record y la colección de tipos del
sistema, el tipo Zig de una instancia real de ese record (los valores que tomaría cada campo
en tiempo de ejecución). `DefinedType` en el ejemplo `aida` es ese mismo cálculo, atado de una
vez a los `type_defs` del sistema, para no repetirlos en cada función de negocio.

### Entidades: `EntityDef`

Una entidad es el nivel contenedor — la unidad representable como grilla —, con la forma
`{fields, pk, fks, uks}`. Se construye con `zigma.defineEntity(.{...})`, que chequea en
compilación que cada nombre de `pk` (y de cada `uk`, y cada campo origen de cada `fk`) sea
un campo de `fields`, y preserva los literales.

### Claves foráneas: `FkDef` / `FkInfo`

Una `fk` referencia la entidad destino **por nombre** (un string, no el valor): eso mantiene
la definición serializable y permite fks circulares y reflexivas. `fields` admite dos formas:
una lista de nombres cuando el campo origen y el destino se llaman igual (`.fields = cursos.pk`),
o un mapa origen→destino cuando no (`.fields = .{ .jefe = "docente" }`). La key del mapa de
`fks` es el nombre de la fk, lo que permite dos fks distintas a la misma entidad (`presidente`
y `vocal` → `docentes`).

Los chequeos de fks tienen dos niveles: `defineEntity` chequea lo local (que los campos origen
existan en `fields`); `zigma.defineEntities(.{...})` chequea lo global del sistema (que la
entidad destino exista, y que sus campos destino sean su pk completa o una de sus uks).

### Reutilización de claves: `extractPk` / `mergePk`

* `zigma.extractPk(entity)` devuelve los campos de la pk de una entidad como un record con el
  tipo exacto, para heredarlos con `zigma.merge` en otra entidad (por ejemplo, `curso` hereda
  las pk de `periodos`, `materias` y `docentes`). Para el resto de los campos no hace falta
  una función especial: `merge` ya deduplica nombres por sí solo.
* `zigma.mergePk(.{pk1, pk2, ...})` une varias pk que pueden superponerse, sin repetir
  elementos y preservando el orden de primera aparición. Se usa para pks combinadas, como la
  de `presencias`, que junta las de `inscripciones` y `clases`. La concatenación con
  duplicados (`a.pk ++ b.pk`) también sirve como pk: `completeEntity` la deduplica.

### Def → Info de una entidad: `completeEntity`

`zigma.completeEntity(entity)` completa una entidad entera: los campos (con `completeRecord`),
la pk (deduplicada), las fks (siempre en la forma de mapa origen→destino, aunque se hayan
escrito como lista) y las uks (tal cual, o vacías si no se declararon).

## Ejemplo: sistema de alumnos (aida)

`examples/aida.zig` describe un sistema de alumnos con este vocabulario. Incluye entidades
independientes (`docentes`, `materias`, `periodos`, `alumnos`) y entidades que heredan claves
de otras:

* `cursos` hereda las pk de `periodos`, `materias` y `docentes` (el docente responsable).
* `clases` extiende la pk de `cursos` agregando `orden`.
* `preguntas` extiende la pk de `clases` agregando `pregunta`, y `opciones` extiende la de
  `preguntas` agregando `opcion` (encadenamiento de herencia de pk en varios niveles).
* `inscripciones` hereda las pk de `cursos` y `alumnos`.
* `presencias` combina, con `mergePk`, las pk de `inscripciones` y `clases`, que comparten
  `periodo` y `materia`: esos campos no se repiten.
* `docentes` tiene una fk reflexiva (`jefe` → `docente`, el jefe de cátedra es otro docente),
  y `mesas` tiene dos fks distintas a `docentes` (`presidente` y `vocal`).

Los tests en `test/aida_test.zig` importan estas definiciones y verifican, para cada tramo del
vocabulario, tanto los casos positivos (en runtime y con `comptime std.debug.assert`) como los
rechazos esperados en compilación, que viven aparte como fragmentos en `test/compile_errors/`
(el equivalente de los `// @ts-expect-error` del repo TypeScript).

## Estructura

* `src/zigma.zig`: el framework descriptor (módulo `zigma`); no conoce ningún sistema
  concreto.
* `src/postgres_ddl.zig`: generación comptime del DDL PostgreSQL inicial.
* `src/postgres_executor.zig`: política transaccional independiente del driver.
* `src/postgres_libpq.zig`: adaptador bloqueante y mínimo sobre `libpq`.
* `src/postgres_migrations.zig`: snapshot, diff estructural y drafts formatted-SQL.
* `src/liquibase_runner.zig`: invocación runtime directa y bloqueante de Liquibase.
* `src/rest.zig`: codecs, routing, JSON, validación y respuestas REST, sin sockets ni base.
* `src/postgres_crud.zig`: CRUD PostgreSQL parametrizado derivado de las entidades.
* `src/std_http.zig`: adaptador HTTP bloqueante y secuencial sobre `std.http`.
* `examples/aida.zig`: el sistema de alumnos descripto con el framework (módulo `aida`).
* `examples/aida_postgres.zig`: mappings y modelo PostgreSQL compilado de AIDA.
* `examples/aida_rest.zig`: codecs de `fecha`/`email` y API REST compilada de AIDA.
* `examples/aida_rest_server.zig`: composición Liquibase → libpq → REST → `std.http`.
* `db/`: snapshot aceptado, changelog raíz, changesets inmutables y drafts.
* `tools/`: workflow de migraciones y comparación estructural vía `pg_catalog`.
* `test/*_test.zig`: tests positivos del descriptor, el DDL y el executor.
* `test/compile_errors/*.zig`: fragmentos que deben fallar la compilación, con el mensaje de
  error esperado listado en `build.zig`.

## Forma de trabajo

Enfoque TDD, avanzando de a pasos chicos: primero el test que muestra el problema, después la
implementación mínima que lo hace pasar. Los tests son fuertes: además de los positivos,
prueban los rechazos esperados como casos de "no compila".

`zig build test` corre todo: tests de runtime y casos de no-compila.

## Estado

En etapa de diseño. Sigue, en Zig, los pasos de
[system-definition](https://github.com/ari-dc-uba-ar/system-definition) (actualmente en su
versión 0.1.1); no incluye todavía el equivalente del test de snapshot en formato TOON de ese
repo, que depende de una librería sin equivalente en Zig.

## Instalación

```sh
zig fetch --save git+https://github.com/ari-dc-uba-ar/zigma-definition.git#v0.1.0
```

Después en `build.zig`:

```zig
const zigma = b.dependency("zigma_definition", .{}).module("zigma");
exe.root_module.addImport("zigma", zigma);

const postgres_ddl = b.dependency("zigma_definition", .{}).module("zigma_postgres_ddl");
exe.root_module.addImport("zigma_postgres_ddl", postgres_ddl);

const postgres_executor = b.dependency("zigma_definition", .{}).module("zigma_postgres_executor");
exe.root_module.addImport("zigma_postgres_executor", postgres_executor);

const postgres_migrations = b.dependency("zigma_definition", .{}).module("zigma_postgres_migrations");
exe.root_module.addImport("zigma_postgres_migrations", postgres_migrations);

const liquibase_runner = b.dependency("zigma_definition", .{}).module("zigma_liquibase_runner");
exe.root_module.addImport("zigma_liquibase_runner", liquibase_runner);

const rest = b.dependency("zigma_definition", .{}).module("zigma_rest");
exe.root_module.addImport("zigma_rest", rest);

const postgres_crud = b.dependency("zigma_definition", .{}).module("zigma_postgres_crud");
exe.root_module.addImport("zigma_postgres_crud", postgres_crud);

const std_http = b.dependency("zigma_definition", .{}).module("zigma_std_http");
exe.root_module.addImport("zigma_std_http", std_http);

// Opcional: requiere headers y biblioteca de libpq.
const postgres_libpq = b.dependency("zigma_definition", .{}).module("zigma_postgres_libpq");
exe.root_module.addImport("zigma_postgres_libpq", postgres_libpq);
```

El paquete también exporta `aida`, descripto en `examples/aida.zig`.

## DDL inicial para PostgreSQL

Los tipos SQL se mantienen separados de los `TypeDef` para que la descripción del sistema
no dependa de una base de datos concreta:

```zig
const postgres_ddl = @import("zigma_postgres_ddl");

const mappings = postgres_ddl.defineTypeMappings(zigma.merge(.{
    postgres_ddl.common_type_mappings,
    .{
        .fecha = postgres_ddl.TypeMapping{ .sql_type = "DATE" },
        .email = postgres_ddl.TypeMapping{ .sql_type = "TEXT" },
    },
}));

const materias_sql = postgres_ddl.createTableDdl(aida.entity_defs, "materias", mappings);
const schema_sql = postgres_ddl.createSchemaDdl(aida.entity_defs, mappings);
```

La salida contiene `CREATE TABLE IF NOT EXISTS`, columnas, PKs, UKs y FKs con nombres
determinísticos. El schema completo ordena primero las tablas referenciadas, admite FKs
reflexivas y rechaza ciclos entre tablas diferentes, que requerirían una segunda fase con
`ALTER TABLE`.

El generador no conecta ni compara contra una base existente. Si una tabla ya existe,
`IF NOT EXISTS` no agrega columnas ni constraints nuevas: cambiar la definición solo cambia
el script generado. Para bases versionadas se usa el workflow de la sección siguiente; este
DDL crudo se conserva para validación, tests y adopción inicial.

## PostgreSQL versionado con Liquibase

Las entidades Zigma siguen siendo el estado deseado. Dos artefactos históricos se versionan
en Git:

* `db/schema.snapshot.json`: último modelo canónico aceptado.
* `db/changes/*.sql`: changesets Liquibase formatted-SQL, ordenados por revisión.

`db/schema_guard.zig` embebe el snapshot y lo compara en compilación. Además, el build normal
ejecuta `check-schema`, que muestra un draft legible cuando existe drift. Ninguno de esos dos
chequeos abre una conexión.

El repositorio fija Liquibase Community **5.0.4**. Instalar esa versión desde la distribución
oficial y agregar el driver PostgreSQL una sola vez:

```sh
liquibase --version                 # debe informar 5.0.4
liquibase lpm add postgresql
```

Se puede indicar la ruta exacta con `-Dliquibase-bin=/ruta/a/liquibase`. El flujo cotidiano es:

```sh
# 1. Modificar entidades o mappings; el build ahora falla mostrando el diff.
zig build

# 2. Crear el único draft permitido. No avanza el snapshot.
zig build migration -Dname=add_example

# 3. Revisar db/drafts/000002_add_example.sql. Los comentarios
#    ZIGMA-BLOCKER requieren SQL PostgreSQL manual y deben eliminarse.

# 4. Reproducir historia + candidato en PostgreSQL descartable, comparar
#    pg_catalog con el SSOT y, solo si coincide, aceptar ambos artefactos.
zig build accept-migration \
  -Dlibpq-prefix="$(brew --prefix libpq)" \
  -Dliquibase-bin=/ruta/a/liquibase
```

Las revisiones tienen seis dígitos y son secuenciales. Un conflicto entre branches se resuelve
rebaseando y regenerando el draft, porque el orden es parte del contrato. Los hashes SHA-256
de los snapshots origen y destino impiden aceptar un draft stale. Los changesets aceptados no
se editan: Liquibase detecta cualquier modificación mediante su checksum.

Los cambios seguros (tabla nueva, columna nullable, quitar `NOT NULL`, nuevas UK/FK) se
renderizan directamente. Drops, posibles renames, columnas nuevas no-null, casts, `SET NOT
NULL`, cambios/remociones de constraints y orden de columnas producen `ZIGMA-BLOCKER`. El
generador nunca infiere `CASCADE`, rename ni conversión de datos; el desarrollador escribe la
operación explícita y `accept-migration` prueba el catálogo resultante.

### Startup versionado

La aplicación ejecuta Liquibase antes de aceptar tráfico. La URL debe ser JDBC; usuario y
password se heredan al hijo mediante variables de ambiente y no aparecen en sus argumentos:

```sh
LIQUIBASE_URL="jdbc:postgresql://localhost:5432/zigma_dev" \
LIQUIBASE_USERNAME=zigma \
LIQUIBASE_PASSWORD=secret \
LIQUIBASE_CHANGELOG=db/changelog-root.yaml \
LIQUIBASE_BIN=/ruta/a/liquibase \
zig build run-postgres-liquibase-bootstrap
```

Liquibase aporta checksums y locking para startups concurrentes. Un error de ejecutable,
conexión, checksum o changeset impide el arranque. `zigma_postgres_executor` y `libpq` siguen
disponibles, pero no aplican el historial versionado.

### Inicialización, adopción y tests

`zig build init-migrations` se usa una sola vez en un sistema sin historia: genera el baseline
sin `IF NOT EXISTS` y el snapshot inicial. Este repositorio ya contiene esa revisión.

Para adoptar una base creada previamente por `postgres_bootstrap`, el comando exige tanto la
URL libpq como la JDBC. Primero construye un schema esperado temporal, compara tablas,
columnas y constraints, comprueba que no exista historia posterior y recién entonces ejecuta
`changelog-sync`:

```sh
DATABASE_URL="postgresql://zigma:secret@localhost:5432/zigma_dev" \
LIQUIBASE_COMMAND_URL="jdbc:postgresql://localhost:5432/zigma_dev" \
LIQUIBASE_COMMAND_USERNAME=zigma \
LIQUIBASE_COMMAND_PASSWORD=secret \
ZIGMA_ACTUAL_SCHEMA=public \
zig build baseline-existing \
  -Dlibpq-prefix="$(brew --prefix libpq)" \
  -Dliquibase-bin=/ruta/a/liquibase
```

La suite pura no necesita servicios externos. La suite completa fija PostgreSQL
`18.4-alpine3.24` y requiere Docker, libpq y Liquibase 5.0.4:

```sh
zig build test
zig build test-migrations \
  -Dlibpq-prefix="$(brew --prefix libpq)" \
  -Dliquibase-bin=/ruta/a/liquibase
```

Reaplicar `CREATE TABLE IF NOT EXISTS` no es una migración. Producción solo recibe historia
aceptada; nunca calcula diferencias contra una base viva durante startup.

## Ejecución transaccional

`zigma_postgres_executor` recibe el string inmutable y cualquier conexión que implemente
estructuralmente `begin`, `exec`, `commit` y `rollback`. De esa forma la política de
transacción no depende de `libpq` ni de las definiciones del sistema:

```zig
const postgres_executor = @import("zigma_postgres_executor");
const postgres_libpq = @import("zigma_postgres_libpq");

const schema_sql = postgres_ddl.createSchemaDdl(aida.entity_defs, mappings);

var connection = postgres_libpq.Connection.init(allocator);
defer connection.deinit();
try connection.connect(database_url);

try postgres_executor.executeSchema(&connection, schema_sql);
```

El executor abre una transacción propia. Si falla la ejecución o el commit, intenta rollback
sin reemplazar el error original. La conexión debe estar fuera de otra transacción;
`zigma_postgres_libpq` chequea esa precondición. El adaptador es deliberadamente pequeño y
bloqueante: ejecuta SQL confiable, conserva el último diagnóstico de PostgreSQL y no incluye
pool ni concurrencia. Para REST también expone queries de texto parametrizadas, resultados
tabulares owned (incluyendo `NULL`) y el último SQLSTATE; la construcción del CRUD permanece
en `zigma_postgres_crud`.

`zig build test` no necesita PostgreSQL ni `libpq`. La integración real usa un contenedor
descartable, un puerto aleatorio y PostgreSQL 18.4:

```sh
zig build test-postgres -Dlibpq-prefix="$(brew --prefix libpq)"
```

En sistemas donde `pkg-config` ya descubre `libpq`, se puede omitir `-Dlibpq-prefix`.

### Ejemplo ejecutable

`examples/postgres_bootstrap.zig` muestra la composición completa. Sus entidades, mappings
y `schema_sql` son constantes evaluadas en compilación; `main` solo lee la conexión y aplica
ese string durante la ejecución:

```sh
DATABASE_URL="postgresql://user:password@localhost/database" \
zig build run-postgres-bootstrap -Dlibpq-prefix="$(brew --prefix libpq)"
```

La URL no se incorpora al binario: se obtiene del ambiente en runtime. El comando termina
con error y muestra el diagnóstico retenido por `libpq` si no puede conectar o aplicar el
schema.

## REST CRUD derivado de las entidades

`zigma_rest.Api(entity_defs, codecs)` produce en compilación la tabla de rutas y el dispatch
para todas las entidades. Los codecs se mantienen separados tanto de `TypeDef` como de los
mappings SQL. El framework incluye `text`, `integer` y `boolean`; AIDA agrega `fecha` ISO
`YYYY-MM-DD` y usa el codec de texto para `email`:

```zig
const codecs = rest.defineCodecs(aida.type_defs, zigma.merge(.{
    rest.common_codecs,
    .{
        .fecha = aida_rest.date_codec,
        .email = rest.text_codec,
    },
}));

const Api = rest.Api(aida.entity_defs, codecs);
var api = Api.init(.{});
var repository = postgres_crud.Repository(aida.entity_defs).init(&connection);
```

Por cada nombre exacto de entidad se exponen `GET`, `POST`, `PUT` y `DELETE` bajo
`/api/<entidad>`. Los filtros de query usan igualdad y `AND`; su orden en SQL siempre sigue
el orden de campos de la entidad. `POST` exige PK y campos efectivos no-null, `PUT` es parcial
y no modifica PK, y `PUT`/`DELETE` exigen al menos un filtro. Las mutaciones usan
`RETURNING *`.

Los identificadores SQL provienen exclusivamente de las definiciones y se escapan. Todos los
valores viajan mediante `$1`, `$2`, etc.; incluso un valor con forma de inyección nunca se
concatena al SQL. Violaciones PostgreSQL de clase SQLSTATE `23` se devuelven como `409`, una
conexión no disponible como `503`, y los diagnósticos internos no aparecen en HTTP.

### Servidor AIDA completo

El ejemplo versionado ejecuta Liquibase antes de abrir libpq y recién entonces comienza a
aceptar requests:

```sh
DATABASE_URL="postgresql://zigma:secret@localhost:5432/zigma_dev" \
LIQUIBASE_URL="jdbc:postgresql://localhost:5432/zigma_dev" \
LIQUIBASE_USERNAME=zigma \
LIQUIBASE_PASSWORD=secret \
HTTP_ADDRESS=127.0.0.1 \
HTTP_PORT=8080 \
zig build run-aida-rest -Dlibpq-prefix="$(brew --prefix libpq)"
```

El adapter de referencia procesa una request por conexión y una conexión por vez, con headers
de hasta 16 KiB y body de hasta 1 MiB. Es deliberadamente simple: todavía no incluye auth,
TLS, CORS, paginación, pooling ni concurrencia.

La suite pura valida routing, codecs, JSON y SQL exacto sin servicios externos. La integración
HTTP real usa un PostgreSQL descartable y un puerto aleatorio:

```sh
zig build test-rest-postgres -Dlibpq-prefix="$(brew --prefix libpq)"
```

## Licencia

MIT. Ver [LICENSE](LICENSE).
