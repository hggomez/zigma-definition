# Referencias de regresión de AIDA

Estas referencias se capturaron antes del modelo normalizado y conservan sus nombres
originales. Se actualizaron explícitamente con los campos `esImportador` y
`fecha_nacimiento` del contrato de AIDA. El snapshot coincide byte por byte con
[`examples/aida/db/schema.snapshot.json`](../../examples/aida/db/schema.snapshot.json).
No se deben regenerar automáticamente para hacer pasar un refactor de los generadores;
los cambios del contrato requieren revisar las expectativas y actualizar estos hashes.

| Archivo | SHA-256 |
|---|---|
| `aida-baseline-before-model.sql` | `0f2a4c19d1b01e860f4605223fc64d8edff9b066a6fea5b2cde7050fcb31ea8b` |
| `aida-bootstrap-before-model.sql` | `673f041874023dfa5ace9273afb11563252efc0ff9af1b20c6185ede9f0ca08a` |
| `aida-snapshot-before-model.json` | `ad7b33e81d0204f14e86c4ce6b7bea07afcc04ae65f24af663b1a467adfee717` |
