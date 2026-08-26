# Cola de ideas de tests

Acá anotamos ideas de tests a medida que surgen en la conversación, para no
perderlas ni implementarlas antes de tiempo. Se sacan de la cola de a una,
en el orden que acordemos en el momento (no necesariamente el de esta
lista), siguiendo TDD: se escribe el test, se muestra en rojo, se espera la
revisión antes de implementar.

## Pendientes (módulo `sql_generator` — esquema de la base de datos)

* **Esquema completo de aida**: `schemaSql` corrido sobre `aida.entity_defs`
  (11 entidades, ya con fks entre ellas) — la demo real de "ver corriendo
  con aida". Sostiene además el paso manual de imprimir el esquema a
  stdout. Quedó explícitamente para después de que NOT NULL/PK/UK/FK
  estuvieran implementados y probados por separado (ya lo están): recién
  ahora se puede escribir con confianza el DDL esperado de las 11
  entidades.

## Hechos (referencia rápida, no repetir)

* Columna simple con su tipo SQL (`createTableSql`, un campo).
* Varios campos, cada uno con el tipo SQL que le corresponde.
* Más de una entidad en un mismo esquema (`schemaSql`, entidades
  independientes, sin fk).
* Mapeo de todos los tipos de dominio del sistema a SQL, incluyendo uno
  respaldado por un struct anidado (`fecha`) — mapea a una sola columna
  opaca, sin necesitar que `sql_generator.zig` mire el `Type` de Zig
  subyacente.
* `NOT NULL` para `nullable: false`, omitido en el default (`aida.alumnos`).
* `PRIMARY KEY` compuesta, todos los campos en orden (fixture ad-hoc
  `combinacion`; ya funcionaba de antes gracias al `pkClause` genérico).
* `UNIQUE` desde `uks` (`aida.materias`).
* `FOREIGN KEY`, mismo nombre origen/destino (fixture ad-hoc `hijo` →
  `padre`).
* `FOREIGN KEY`, columna renombrada / fk reflexiva (fixture ad-hoc
  `persona.jefe`).
* Dos fks distintas a la misma entidad, sin pisarse (fixture ad-hoc
  `disputa` → `objetivo` ×2).
* Fks cíclicas entre dos entidades distintas, sin loopear ni requerir que
  la tabla referenciada ya exista (fixture ad-hoc `nodo_a` ↔ `nodo_b`);
  de paso confirma que `zigma.defineEntities` acepta el ciclo a nivel
  framework.
* Tipo sin mapeo SQL no compila (`test/compile_errors/
  sql_unknown_type_mapping.zig`, mensaje `"type 'x' has no SQL mapping"`).
* Pk siempre `NOT NULL`, sin importar el `nullable` del campo (fixture
  `combinacion`, pk `a`,`b`, ninguno con `nullable: false` explícito).
