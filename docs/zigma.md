# How `zigma` describes a system

This is a walk through `src/zigma.zig`: what each piece is for, and how they nest.
It goes from the smallest building block up to a whole system, so each section
only uses what was already introduced.

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
is [validators.md](validators.md) (not implemented).

Everything below is a **comptime value**: checked while the program compiles,
then available as ordinary data at runtime. The Zig types of instances (the
actual field values of a row) are *derived* from those values, so field names
are written once.

```
TypeDef                          domain type (a Zig type with a name)
  └─ type collection             defineTypes / common_type_defs
       └─ Field Def              one column: type name + optional extras
            └─ Record Def        a row shape (record)
                 ├─ instance     RecordInstanceType  → runtime Zig struct
                 ├─ Record Info  completeRecord      → FieldInfo per field
                 └─ Entity Def   defineEntity        → grid: fields + keys
                      ├─ pk / uks                    name lists into fields
                      ├─ Fk Def                      link to another entity
                      ├─ reuse                       extractPk / merge / mergePk
                      ├─ Entity Info                 completeEntity
                      └─ system                      defineEntities
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
    materia: []const u8,        // "text"
    denominacion: []const u8,   // "text"
}
```

aida binds this once to its own collection so business code does not repeat
`type_defs`:

```zig
pub fn DefinedType(comptime rec: anytype) type {
    return zigma.RecordInstanceType(type_defs, rec);
}

pub fn validarCargo(cargo_sin_validar: DefinedType(cargo)) error{AyudanteNoPuedeDirigir}!void {
    // cargo_sin_validar.denominacion is []const u8, .orden is i64, …
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
     (`.fields = cursos.pk` means “the fields called `periodo` and `materia`
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

## 9. Entity Def: `defineEntity`

An entity is the unit that can be shown as a grid: a record plus the keys that
make rows identifiable and related.

```zig
pub const materias = zigma.defineEntity(.{
    .pk = .{"materia"},
    .uks = .{ .denominacion = .{"denominacion"} },
    .fields = materia,
});
```

| Property | Required | Role |
|----------|----------|------|
| `fields` | yes | a record Def (the columns) |
| `pk`     | yes | list of field names: the primary key |
| `fks`    | no  | named foreign keys (section 8) |
| `uks`    | no  | named unique keys; each value is a list of field names |

`defineEntity` checks what is **local** to this entity:

- every pk name is a field of `fields`;
- every uk name is a field of `fields`;
- every fk **source** field is a field of `fields`;
- no unknown properties on the entity or on each fk.

It then returns a normalized struct: the pk becomes a real array of names,
and missing `fks` / `uks` become empty structs. The record in `fields` is
kept as-is (still a Def, not yet an Info).

Convention in aida: the record is singular (`materia`), the entity is plural
(`materias`). The entity’s name in `defineEntities` is that plural string,
which is also what fks put in `.entity`.

---

## 10. Reusing keys: `extractPk` and `mergePk`

SSOTIGAD’s “good repetition” is inheritance of keys, not copy-paste of field
lists.

### `extractPk(entity)`

Returns the pk fields of an entity **as a record Def** (the same field defs,
only those names). That record can be `merge`d into another record:

```zig
pub const curso = zigma.record(type_defs, zigma.merge(.{
    zigma.extractPk(periodos),   // field `periodo`
    zigma.extractPk(materias),   // field `materia`
    zigma.extractPk(docentes),   // field `docente` (responsable)
}));
```

`curso` now has those three fields with the original defs. `merge` already
deduplicates names if two extracted pks share a field.

### `mergePk(.{ pk1, pk2, ... })`

Joins **name lists**. Overlapping names appear once, in first-appearance
order. Used when the new entity’s pk *is* the combination of other pks,
possibly plus extra fields:

```zig
.pk = zigma.mergePk(.{ cursos.pk, .{"orden"} })           // clases
.pk = zigma.mergePk(.{ inscripciones.pk, clases.pk })     // presencias
```

`presencias` is the interesting case: `inscripciones` and `clases` both
include `periodo` and `materia`. `mergePk` keeps each name once. Those shared
fields then participate in *both* foreign keys.

Concatenating arrays (`a.pk ++ b.pk`) is also a valid pk, even with
duplicates: `completeEntity` deduplicates. `mergePk` is the explicit form
when writing the Def.

---

## 11. Entity Info: `completeEntity`

`completeEntity(entity)` is Def → Info for a whole entity. One form, nothing
implicit:

- `fields` → `completeRecord` (every field a `FieldInfo`);
- `pk` → deduplicated name list (same rule as `mergePk`);
- `fks` → every fk’s `fields` rewritten as a **source → target map**, even if
  the Def used the list shorthand;
- `uks` → unchanged (or the empty default from `defineEntity`).

After completion there is no “list of names” spelling for an fk. A generator
only has to understand maps.

`completeEntity` does not check the target side of fks. It only normalizes
this entity.

---

## 12. The system: `defineEntities`

A system is a struct of entities, each already passed through `defineEntity`.
This is the first place **all** entities are known, so it is the first place
the target side of foreign keys can be checked.

```zig
pub const entity_defs = zigma.defineEntities(.{
    .docentes = docentes,
    .materias = materias,
    // …
});
```

For every fk of every entity:

1. `fk.entity` must be the name of an entity in this struct.
2. The **target** field names must be exactly the target’s full primary key,
   or exactly one of its unique keys.

That is why `materias` declares `uks = .{ .denominacion = .{"denominacion"} }`:
so another entity could point at a materia by denominación, not only by pk.
A fk that names a random subset of columns is rejected.

Like `record` and `defineTypes`, `defineEntities` returns its argument
unchanged. The value you wrote is the value you get; the function’s job is
the compile-time check.

Reflexive and circular fks work because targets are names: `docentes.jefe`
points at `"docentes"` while `docentes` is still being listed.

---

## How a definition is meant to be read

For a concrete entity, the story is always the same:

1. Name the domain types (`TypeDef` in a `defineTypes` collection).
2. Describe the row (`record` of field defs).
3. Wrap it as a grid (`defineEntity`: pk, optional uks and fks).
4. If the row includes another entity’s identity, inherit it (`extractPk` +
   `merge`, and `mergePk` for the new pk).
5. Put every entity in `defineEntities` so links are globally consistent.
6. When a tool needs “everything explicit”, call `completeRecord` /
   `completeEntity`. When Zig code needs an actual row, use
   `RecordInstanceType` (or aida’s `DefinedType`).

The human-facing names stay in the Defs. The Infos and instance types are
computed, not maintained by hand.
