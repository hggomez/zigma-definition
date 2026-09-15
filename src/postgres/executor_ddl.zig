//! Ejecución transaccional de un string inmutable de DDL PostgreSQL.
//!
//! La conexión es estructural: se puede pasar cualquier valor de tipo puntero
//! con métodos `begin`, `exec`, `commit` y `rollback`. Así, la política de
//! transacciones no depende de un driver PostgreSQL concreto.

/// Ejecuta el DDL completo de un schema en una única transacción.
///
/// La conexión pertenece a quien llama, que debe entregarla sin una transacción
/// activa. Si falla la ejecución o el commit, se intenta un rollback;
/// un fallo del rollback nunca reemplaza el error original.
pub fn executeSchema(connection: anytype, ddl: []const u8) !void {
    // `begin` es el primer efecto externo. Si falla, la ejecución se detiene acá
    // y todavía no se registró el `errdefer` siguiente. Así no se ejecuta un
    // rollback inútil o peligroso sobre una transacción que nunca empezó.
    try connection.begin();

    // `errdefer` se diferencia de `defer`: solo corre si la función sale con error.
    // Registrarlo inmediatamente después de un BEGIN exitoso cubre los dos puntos
    // de fallo posteriores: ejecutar el DDL y confirmar la transacción.
    //
    // Se intenta el rollback sin garantizar su éxito. `catch {}` descarta su error
    // para que una falla durante la limpieza no reemplace el error original de SQL
    // o COMMIT, que explica mejor por qué se inició la salida por error.
    errdefer connection.rollback() catch {};

    // El DDL inmutable se pasa como una unidad. Esta capa no lo divide, reescribe,
    // inspecciona ni copia; solo se ocupa de la política de transacciones.
    try connection.exec(ddl);

    // Un commit exitoso termina la función normalmente. Como un retorno normal
    // no activa `errdefer`, no se intenta un rollback después.
    try connection.commit();
}
