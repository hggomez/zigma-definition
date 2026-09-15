# Object validators (named behavior)

**Status:** not implemented. This is a viable shape, not a spec of current code.

Defs stay serializable data. A validator is a **behavior referenced by name**, with the
function registered apart — the same rule as [zigma.md](zigma.md) and the README
(behaviors are never a `fn` field on the entity). Both generators that accept a row
(WASM and HTTP) can look that name up and call the implementation after they already
have a typed instance.

This is input validation of **one object** (one row). It is not a Zig constructor, and
it is not a check against the rest of the store.

---

## The split: role name vs implementation

Give the behavior a **reserved role name** that both generators know, for example
`validate`. That name is the contract: “if this entity has an object validator, this
is how you find it.”

The function itself lives in a **registry on `system`**, keyed by entity name, next to
the existing optional `seeds`:

```zig
// system.zig — illustrative, not in the tree
pub const type_defs = aida.type_defs;
pub const entity_defs = aida.entity_defs;
pub const seeds = .{ /* ... */ };

pub const validators = .{
    .clases = validateClase, // fn (row: ClaseRow) ValidateError!void
};
```

An entity with no entry is valid: no extra check. Same idea as `widgets.js` (`domain
type → { make, read }`): the page looks up a widget by type name; here WASM and HTTP
look up a validator by entity name. Unknown → skip.

`zigma` does not import the registry. Generators import `system` already.

---

## Why it fits the core

`defineEntity` only accepts `fields`, `pk`, `fks`, `uks`. A `fn` on the Def would be
rejected today and would break serializability.

A **string** on the Def (`validate = "check_clase"`) is optional later (DevXP: fail at
declaration if the name is missing from the registry). It is not required for the
approach to work. The generators can treat `system.validators` as a convention, the
way they already treat `system.seeds`, with **no change** to `src/zigma.zig`.

`TypeDef` stays `{ .Type = T }`. Field defs stay type / label / nullable / is_name /
description. Schema checks (`record`, `defineEntity`, `defineEntities`) keep validating
the description, not row values.

---

## Call sites (already there)

Both sides build a `RecordInstanceType` and then accept the row. That is the hook:
parse → **validate** → accept.

| Path | After | On failure |
| --- | --- | --- |
| WASM `build_row` / `create_row` | `parseFieldValue` into the entity’s row in `buildRowJson` | return 0; `error_buf` (Post and Save both go through `build_row`) |
| HTTP `POST /{entity}` | `parseFromSlice(Row, body)` | `400 {"status":"invalid"}` (already used for bad JSON) |
| HTTP `PUT /{entity}?pk` | same parse, after pk match | same |

Dispatch is the same `inline for` over entity names both files already use:
`@hasField(system.validators, name)` then call with the typed row.

`GET` and `DELETE` do not build a new object; they do not call this. JSON stringify
does not call it.

Seeds and tests that write a struct literal (`DefinedType(alumno){ ... }`) **will not**
run it unless those paths call the same function. `RecordInstanceType` remains a plain
struct. The generators are the constructor-like boundary, not Zig’s `.{ }`.

---

## What a validator may do

**Viable on both WASM and HTTP** (same Zig `fn`, compiled twice):

- Checks on **one row**: ranges, combinations of fields, “this `fecha` is a real date”,
  format rules that are not the Zig type.
- Freestanding-safe code: no filesystem, no HTTP, no process. WASM is
  `wasm32-freestanding`.
- Failure as `error` plus a **static** message string (WASM has a fixed `error_buf`,
  not a general allocator for messages).

**Not viable as a shared check** (backend has the lists; WASM only has the row being
edited):

- Uniqueness, “this pk already exists”, FK existence, “does this `alumno` exist”.
  Those can run on HTTP only, or WASM must be given that data. They are a different
  behavior, not this one.

---

## Signature (sketch)

Per entity, the row type is different, so the registry cannot be one `fn (anytype)`
value. Each entry is a function of that entity’s `RecordInstanceType`. Generators
pick it at comptime by entity name.

Something in this family is enough:

```zig
const ValidateError = error{ InvalidRow };

fn validateClase(row: zigma.RecordInstanceType(type_defs, clase.fields)) ValidateError!void {
    if (row.orden < 1) return error.InvalidRow;
    // ...
}
```

Returning `error{InvalidRow}` is enough if the generator supplies a generic message.
Returning a static `[]const u8` (or writing into a caller-provided buffer) is better
if the UI should show why. Do not return allocated strings unless the caller passes
an allocator — HTTP has one; WASM today does not on this path.

---

## Core vs generators

| Piece | Role |
| --- | --- |
| `zigma` | Unchanged, or later an optional string on the entity Def. Does not store or call `fn`s. |
| `system.validators` | Implementations, keyed by entity name. Optional, like `seeds`. |
| WASM `buildRowJson` | Call after a typed row exists, before stringify / `js_send_post`. |
| HTTP POST/PUT | Call after a typed row exists, before append / replace. |
| `widgets.js` | Unrelated: DOM for a **domain type**. Validators are Zig, for an **entity**. |

Teaching the name to `zigma` is DevXP, not a viability requirement. If the Def gains a
string, `defineEntities` still should not import implementations; the mismatch check
belongs where the registry is assembled (`system`), same as fk targets being strings
until the whole map of entities is known.

---

## Summary

Object validation is a reserved behavior name, implementations in `system`, called from
WASM and the backend after parse and before accept. It covers per-row rules. It does
not replace typed parse, does not run on struct literals by itself, and does not see
other rows unless a later, separate hook is designed for that.
