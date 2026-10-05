# How `zigma` describes a system

Esta guía recorre el núcleo de `src/core/`: para qué sirve cada pieza y cómo se
combinan. Va desde los elementos más pequeños hasta un sistema completo.
`src/core/zigma.zig` sigue siendo la entrada pública de `@import("zigma")`.

## Cómo recorrer los archivos

| Archivo en `src/core/` | Qué contiene |
| --- | --- |
| `zigma.zig` | La lista de nombres públicos; reexporta las implementaciones. |
| `records.zig` | Tipos de dominio, campos, validación y defaults de records, tipos de instancia y `merge`. |
| `entities.zig` | `Entity`, PK, UK, FK y dependencias de reglas; valida definiciones y registros, normaliza metadatos y genera tipos concretos. |
| `model.zig` | `Framework`: valida la identidad del tipo registrado, reúne el contrato normalizado y ofrece `Row`, `Patch` y `Filters`. |
| `names.zig` | Tres helpers internos para reconocer strings, comparar nombres y comprobar pertenencia a una lista. |

Para leer la implementación, conviene seguir `records.zig` → `entities.zig` →
`model.zig`. El modelo utiliza los dos anteriores; las entidades utilizan los
records. Los helpers de nombres no dependen de ninguno de ellos. Las importaciones
entre archivos son internas: los consumidores siguen usando el módulo `zigma`.

Por ejemplo, un campo `.id = .{ .type = "integer" }` recibe `nullable = true` al
completar su record en `records.zig`. Si pertenece a la PK, `entities.zig` lo marca
no-null al completar la entidad, sin cambiar el record original. `Entity` genera
el tipo de fila; `model.zig` lo comprueba y lo devuelve desde `Model.Row`.
También reúne los metadatos en `Model.info`; el campo `id` de la fila tendrá `i64`. La conversión de un campo normalizado a `T` o
`?T` vive solamente en `records.zig` y se comparte con entidades y modelo.

Esta separación conserva el comportamiento: las reglas todavía describen
dependencias serializables; no ejecutan funciones de validación automáticamente.

## Lógica de negocio con entidades concretas

El ejemplo [aida.zig](../examples/aida/src/aida.zig) declara
`Docente = zigma.Entity(type_defs, docente_def)` y utiliza ese tipo directamente:

```zig
pub fn validarDocente(value: Docente) DocenteValidationError!void {
    const cargo_value = value.cargo orelse return;
    const normalized_cargo = std.mem.trim(u8, cargo_value, " \t\r\n");
    if (!std.ascii.eqlIgnoreCase(normalized_cargo, "teorico")) return;
    const experiencia = value.experiencia orelse
        return error.TeoricoRequiereCincoAniosExperiencia;
    if (experiencia < 5) return error.TeoricoRequiereCincoAniosExperiencia;
}
```

La regla lee dos campos, pero recibe la entidad completa. No repite sus tipos ni su
nulabilidad fuera del contrato. `Model.Row("docentes")` devuelve exactamente `Docente`.

```zig
try aida.validarDocente(.{
    .docente = "d1",
    .apellido = null,
    .nombres = "Ada",
    .cargo = "teorico",
    .email = null,
    .email_alternativo = null,
    .jefe = null,
    .telefono = null,
    .experiencia = 5,
    .esImportador = null,
});
```

Si `experiencia` deja de admitir null, `Docente` tendrá `i64` para ese campo y el
compilador señalará el `orelse` incompatible. Si se agrega un campo, los literales de
fila completa deberán incluirlo aunque sea ajeno a la regla y admita null.

REST construye la entidad con una conversión genérica y llama al adaptador tipado;
este delega en `validarDocente`. Los [tests](../test/aida_test.zig) conservan nueve
casos con nulos, espacios, mayúsculas y el límite de cinco años. También comprueban
que modificar datos ajenos a la regla no cambie el resultado. El registro y su
relación con los metadatos `rules` se explican en [validators.md](validators.md).

## El vocabulario

`zigma` does not generate tables, endpoints, or screens. It is the vocabulary
used to *describe* a system so that other tools can. The example system in
`examples/aida/src/aida.zig` (students, courses, classes, …) is written with this
vocabulary; the library itself does not know aida.

Two words appear everywhere:

- A **Def** is what a human writes: only the parts that have meaning. Defaults
  can be omitted.
- An **Info** is that same Def with every default filled in. Generators consume
  Infos, not Defs.

Both are plain data (structs, strings, lists). Special behavior is referenced
by name, never embedded as a function. A viable shape for per-row input checks
is described in [validators.md](validators.md), including the implemented REST registry
and the pending automatic binding of named rules.

Las definiciones se evalúan en compilación y pueden convertirse en metadatos
ordinarios para runtime. Los tipos Zig se derivan de ellas; viven en `TypeDef`,
los tipos concretos y el registro, fuera de `Model.info`. Los nombres y tipos de
los campos se escriben una sola vez.

```
TypeDef                          domain type (a Zig type with a name)
  └─ type collection             defineTypes / common_type_defs
       └─ Field Def              one column: type name + optional extras
            └─ Record Def        a row shape (record)
                 ├─ instance     RecordInstanceType  → runtime Zig struct
                 ├─ Record Info  completeRecord      → FieldInfo per field
                 └─ Entity Def   valor descriptivo   → fields + claves + reglas
                      ├─ pk / uks                    name lists into fields
                      ├─ Fk Def                      link to another entity
                      ├─ reuse                       extractPk / merge / mergePk
                      ├─ Entity Info                 completeEntity
                      ├─ tipo concreto               Entity(type_defs, definition)
                      └─ registro Type + definition  defineEntities → Framework
```

---

## 1. Domain type: `TypeDef`

A domain type is a name the system uses for a kind of value, plus the Zig type
that actually holds that value at runtime.

```zig
zigma.TypeDef{ .Type = i64 }
```

That is the whole struct: one field, `Type`. The *name* of the type is not
inside `TypeDef`; it is the field name in the collection that contains it
(`.integer = TypeDef{ .Type = i64 }` means the domain type is called
`"integer"`).

Why a wrapper instead of using Zig types directly? Records refer to types **by
name** (a string). Names stay serializable, and the Zig type is looked up later
when an instance type is needed.

---

## 2. Type collection: `defineTypes` and `common_type_defs`

A type collection is a struct whose fields are `TypeDef`s. Each field name is a
domain-type name.

`zigma.common_type_defs` is the starting set every system can reuse:

| Name      | Zig type     |
|-----------|--------------|
| `text`    | `[]const u8` |
| `integer` | `i64`        |
| `boolean` | `bool`       |

A system extends that set with `merge` (section 7) and then **declares** the
result with `defineTypes`. `defineTypes` does not change the value: it checks
that every field is a `TypeDef` (or an anonymous struct with the same shape,
`{ .Type = ... }`) and returns the collection as-is.

The check lives at the declaration site on purpose. Without it, a malformed
collection would only fail the first time some record used it, far from the
mistake.

In aida:

```zig
pub const type_defs = zigma.defineTypes(zigma.merge(.{ zigma.common_type_defs, .{
    .fecha = zigma.TypeDef{ .Type = Fecha },
    .email = zigma.common_type_defs.text,   // an alias of text
} }));
```

After this, field defs may say `.type = "fecha"` or `.type = "email"`.

---

## 3. Field Def

A field is one column of a row. It is an anonymous struct. The only required
property is `type`: the **name** of a domain type in the collection.

```zig
.{ .type = "text" }
```

Optional properties:

| Property      | Meaning | Default when omitted |
|---------------|---------|----------------------|
| `label`       | Human-facing name | the field name, `_` replaced by space |
| `nullable`    | whether the value may be absent | `true` |
| `is_name`     | this field is the display name of the row | `false` |
| `description` | extra text for humans / generators | `""` |

`is_name` may only be written as `true`. Writing `false` is rejected: false is
already the default, so spelling it would only look like a real choice.

Unknown properties are rejected. `type` must be a string that exists in the
type collection.

A field def can be reused by copying it. aida’s `asignacion` does not
re-describe `docente`; it takes `docente.docente` (the field def named
`docente` inside the `docente` record).

---

## 4. Field Info: `FieldInfo`

`FieldInfo` is the completed field: every property present, no defaults left
implicit.

```zig
pub const FieldInfo = struct {
    type: []const u8,
    is_name: bool,
    nullable: bool,
    label: []const u8,
    description: []const u8,
};
```

`type` is still the domain-type **name**, not the Zig type. Completing a field
does not look up `TypeDef`; it only fills Def defaults.

---

## 5. Record Def: `record`

A record is a struct of field defs. It describes a row: which columns it has,
in which order, with which domain types.

```zig
pub const materia = zigma.record(type_defs, .{
    .materia = .{ .type = "text" },
    .denominacion = .{
        .type = "text",
        .label = "denominación",
        .nullable = false,
        .is_name = true,
        .description = "si corresponde a más de una carrera, aclarar en el nombre",
    },
});
```

`record(type_defs, rec)` is the framework’s `satisfies`: it checks that `rec`
is a well-formed record over that type collection, and **returns `rec`
unchanged**. The literal type is kept, including which optional properties
each field actually wrote. That matters later: `completeRecord` can tell
“this field omitted `label`” from “this field set `label`”.

A record is not yet an entity. It has no primary key, no foreign keys. It is
only a shape of fields. Several entities can share ideas from the same
records; an entity *wraps* a record as its `fields`.

---

## 6. What a record Def produces

Two different things are derived from the same Def.

### Runtime instance: `RecordInstanceType`

`RecordInstanceType(type_defs, rec)` builds the Zig struct of **values**: each
field name paired with the `Type` of the domain type it named.

For `materia` that is, conceptually:

```zig
struct {
    materia: ?[]const u8,       // "text", nullable por default
    denominacion: []const u8,   // "text"
}
```

AIDA publica un alias por record para usarlo como tipo en las funciones:

```zig
pub const Cargo = zigma.RecordInstanceType(type_defs, cargo);

pub fn validarCargo(cargo_sin_validar: Cargo) error{AyudanteNoPuedeDirigir}!void {
    if (!(cargo_sin_validar.puede_dirigir orelse false)) return;
    const denomination = cargo_sin_validar.denominacion orelse return;
    if (std.ascii.findIgnoreCase(denomination, "ayudante") != null)
        return error.AyudanteNoPuedeDirigir;
}
```

The Def is still the source of truth. The instance type is computed from it.

### Record Info: `RecordInfoOf` and `completeRecord`

`RecordInfoOf(RecordDefType)` is the type of a completed record: same field
names, every field a `FieldInfo`.

`completeRecord(rec)` fills the defaults:

- `is_name`: `false` unless written
- `nullable`: `true` unless written
- `description`: `""` unless written
- `label`: the explicit label, or the field name with `_` → space

After `completeRecord(materia)`, `denominacion.label` is `"denominación"`
(written) and `materia.label` is `"materia"` (derived). Generators and the
WASM demo read this Info, not the original Def.

---

## 7. Combining structs: `merge` / `Merged`

Records and type collections are structs. To extend one with another, `zigma`
offers the equivalent of a TypeScript object spread `{...a, ...b}`.

```zig
zigma.merge(.{ a, b, extra })
```

Rules:

- Field **order** is first appearance: a name keeps the position where it first
  showed up.
- If the same name appears in several parts, the **last** part wins (its type
  and its value).
- `parts` is a tuple of structs. `Merged(@TypeOf(parts))` is the resulting
  struct type.

This is how aida adds `fecha` and `email` on top of `common_type_defs`, and how
a child record inherits another entity’s primary-key fields (next sections)
without retyping them.

`merge` does not know about keys or entities. It only merges structs. Using it
on record defs, type collections, or any other named structs is the same
operation.

---

## 8. Foreign-key Def

A foreign key says: some of *this* entity’s fields identify a row in *another*
entity.

Two design choices matter for everything that follows.

1. The target entity is a **string name**, not the entity value. Definitions
   stay serializable, and circular or reflexive keys are representable (a
   docente’s `jefe` is another docente; that cannot be written if the target
   had to be the object currently being defined).

2. The field mapping has **two spellings**:
   - a **list of names** when source and target fields are named the same
     (`.fields = curso_def.pk` means “the fields called `periodo` and `materia`
     here are `periodo` and `materia` over there”);
   - a **source → target map** when they are not
     (`.fields = .{ .jefe = "docente" }`).

The fk itself lives in a map whose **key is the fk’s name**. That name is what
lets one entity have two different keys to the same target (`mesas` has
`presidente` and `vocal`, both to `docentes`).

```zig
.fks = .{
    .jefe = .{ .entity = "docentes", .fields = .{ .jefe = "docente" } },
}
```

Required properties: `entity` and `fields`. Nothing else.

At this level only the **source** side can be checked (those field names must
exist on this entity). Whether `"docentes"` exists, and whether `docente` is
actually its primary key, needs the whole system — that is `defineEntities`.

---

## 9. Definición de entidad y tipo concreto: `Entity`

Una entidad agrega las claves y relaciones a un record. Conviene distinguir las
cuatro piezas sin repetir la descripción de sus campos:

```zig
// Record: los campos y su nulabilidad declarada.
pub const materia = zigma.record(type_defs, .{
    .materia = .{ .type = "text" },
    .denominacion = .{ .type = "text", .nullable = false },
});

// Definición de entidad: restricciones sobre ese record.
pub const materia_def = .{
    .pk = .{"materia"},
    .uks = .{ .denominacion = .{"denominacion"} },
    .fields = materia,
};

// Tipo de datos: ya puede usarse en funciones y arrays, sin Framework.
pub const Materia = zigma.Entity(type_defs, materia_def);
const materias_iniciales = [_]Materia{
    .{ .materia = "AlgoI", .denominacion = "Algoritmos I" },
};

// Registro: el nombre plural sigue identificando la tabla y la ruta.
pub const entity_defs = zigma.defineEntities(.{
    .materias = .{ .Type = Materia, .definition = materia_def },
});
```

`Entity` valida los dominios, los campos y las restricciones locales. La definición
requiere `fields` y `pk`; puede omitir `fks`, `uks` y `rules`. Todos los nombres de
claves y dependencias deben existir; las reglas no admiten dependencias repetidas.
La comprobación de destinos de FK se hace al reunir el registro completo.

El resultado de `Entity` tiene solo los campos de datos y no lleva defaults ni
metadatos ocultos. En el ejemplo, `Materia.materia` es `[]const u8`, porque es PK.
Una instancia de `RecordInstanceType(type_defs, materia)` mantiene `?[]const u8`
para ese campo: la restricción pertenece a la entidad.

La definición es un valor, `Materia` es un tipo y `entity_defs.materias` es la
asociación de ambos. Para leer las restricciones se usa `materia_def` o
`Model.info.materias`, no `Materia.definition`.

---

## 10. Reusing keys: `extractPk` and `mergePk`

SSOTIGAD’s “good repetition” is inheritance of keys, not copy-paste of field
lists.

### `extractPk(definition)`

Returns the pk fields of an entity **as a record Def** (the same field defs,
only those names). That record can be `merge`d into another record:

```zig
pub const curso = zigma.record(type_defs, zigma.merge(.{
    zigma.extractPk(periodo_def),   // campo periodo
    zigma.extractPk(materia_def),   // campo materia
    zigma.extractPk(docente_def),   // campo docente (responsable)
}));
```

`curso` now has those three fields with the original defs. `merge` already
deduplicates names if two extracted pks share a field.

### `mergePk(.{ pk1, pk2, ... })`

Joins **name lists**. Overlapping names appear once, in first-appearance
order. Used when the new entity’s pk *is* the combination of other pks,
possibly plus extra fields:

```zig
.pk = zigma.mergePk(.{ curso_def.pk, .{"orden"} })           // clases
.pk = zigma.mergePk(.{ inscripcion_def.pk, clase_def.pk })     // presencias
```

`presencias` is the interesting case: `inscripciones` and `clases` both
include `periodo` and `materia`. `mergePk` keeps each name once. Those shared
fields then participate in *both* foreign keys.

Concatenating arrays (`a.pk ++ b.pk`) is also a valid pk, even with
duplicates: `completeEntity` deduplicates. `mergePk` is the explicit form
when writing the Def.

---

## 11. Entity Info: `completeEntity`

`completeEntity(definition)` is Def → Info for a whole entity. One form, nothing
implicit:

- `fields` → `completeRecord` (every field a `FieldInfo`);
- `pk` → deduplicated name list (same rule as `mergePk`);
- `fks` → every fk’s `fields` rewritten as a **source → target map**, even if
  the Def used the list shorthand;
- `uks` → conserva la definición o usa una colección vacía si se omitió;
- `rules` → dependencias serializables, vacías si se omitieron.

Los campos PK quedan no-null y el record original conserva su nulabilidad.
`completeEntity` acepta directamente la definición descriptiva, sin registro ni tipo.

After completion there is no “list of names” spelling for an fk. A generator
only has to understand maps.

`completeEntity` does not check the target side of fks. It only normalizes
this entity.

---

## 12. Registro y modelo: `defineEntities` y `Framework`

`defineEntities` recibe asociaciones con exactamente `.Type` y `.definition`.
Verifica la forma del registro y las relaciones entre sus definiciones:

```zig
pub const entity_defs = zigma.defineEntities(.{
    .docentes = .{ .Type = Docente, .definition = docente_def },
    .materias = .{ .Type = Materia, .definition = materia_def },
    // …
});
pub const Model = zigma.Framework(type_defs, entity_defs);
```

Para cada FK, el destino debe existir y los campos referenciados deben coincidir
con la PK completa o una UK completa. Por eso `materia_def` declara la UK de
`denominacion`: otra entidad puede identificar una materia por ese campo. Un
subconjunto cualquiera de columnas no constituye una clave válida.

Las relaciones reflexivas y circulares siguen siendo nombres de entidades. No
hace falta construir un tipo que contenga otro tipo para expresar una FK.
El generador DDL conserva su restricción sobre ciclos entre tablas diferentes.

`defineEntities` devuelve el registro sin modificarlo. `Framework` vuelve a
validarlo y exige que cada tipo sea exactamente el generado con sus dominios y
su definición. Un registro incompatible produce un error localizado:

```zig
const Manual = struct { docente: []const u8 };
const Invalid = zigma.Framework(type_defs, .{
    .docentes = .{ .Type = Manual, .definition = docente_def },
}); // Error: entity 'docentes': registered Type does not match Entity(type_defs, definition)
```

`Model.Row("docentes") == Docente`. El modelo ofrece también `Patch` y `Filters`;
los metadatos serializables permanecen en `Model.info`,
sin incluir las asociaciones ni valores Zig `type`.

Si cambia la nulabilidad o el dominio de un campo, `Entity` cambia su tipo y el
cambio se refleja en los consumidores. Si se conserva por error un tipo anterior
en el registro, la comprobación de identidad lo rechaza. Si se agrega un campo,
los literales de fila completa deben proporcionarlo aunque admita null.

---

## Cómo leer una definición

1. Nombrar los dominios con `TypeDef` y `defineTypes`.
2. Describir los campos en un `record`.
3. Agregar claves y relaciones en una definición `*_def`, heredando campos con
   `extractPk` y `merge` cuando corresponde.
4. Generar un tipo concreto con `Entity(type_defs, definition)`.
5. Asociar el nombre plural con el tipo y la definición en `defineEntities`.
6. Construir `Framework` para que los generadores compartan `Model.info` y los
   tipos derivados. La lógica de negocio puede recibir el tipo concreto directamente.

`RecordInstanceType` sigue disponible para records independientes; AIDA publica
`Cargo` como alias de su tipo de instancia. Los tipos de entidad incorporan además sus restricciones de PK.
