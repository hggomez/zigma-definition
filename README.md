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
* `examples/aida.zig`: el sistema de alumnos descripto con el framework (módulo `aida`).
* `test/aida_test.zig`: los tests positivos.
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

Esta primera versión no ejecuta el SQL ni compara contra una base existente. Si una tabla
ya existe, `IF NOT EXISTS` no agrega columnas ni constraints nuevas: cambiar la definición
solo cambia el script generado. Changelog, introspección y migraciones quedan para una fase
posterior.

## Licencia

MIT. Ver [LICENSE](LICENSE).
