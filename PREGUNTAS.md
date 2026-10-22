# Preguntas para el docente

Preguntas que surgen mientras avanzamos y que conviene consultar antes de decidir. Cada una
con el contexto necesario para entenderla sin leer el resto del repo.

## 1. ¿Cómo se indica en el SSOT el uso de las reglas?

**Contexto.** Las reglas de dominio se escriben una vez en Zig y se declaran con
`zigma.defineRules(type_defs, .{ .nombre = .{ .record = ..., .rule = ... } })`: una regla es
una validación sobre una instancia de un record (`error{...}!void`). De esa declaración ya
se generan un módulo WASM por sistema y su `rules.ts`, que el backend TypeScript puede
llamar (ver la sección "Reglas de dominio" de `GOALS.md`).

Lo que el SSOT todavía **no dice** es *cuándo* se aplica cada regla: nada indica, por
ejemplo, que `validarCargo` tenga que correr antes de dar de alta o modificar algo, ni sobre
qué entidad. En aida, además, `cargo` es un record sin entidad propia, así que hoy esa
regla no tendría dónde dispararse.

**Pregunta.** ¿Cómo debería expresarse en el SSOT el uso de una regla? Por ejemplo: atada al
record (corre cada vez que se escribe una instancia de ese record, en cualquier entidad que
lo use), atada a una entidad y una operación (antes de `insert`/`update` de `docentes`), u
otra forma que tenga más sentido en SSOTIGAD.
