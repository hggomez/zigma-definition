//! Transactional execution of an immutable PostgreSQL schema DDL string.
//!
//! The connection is structural: callers may provide any pointer-like value
//! with `begin`, `exec`, `commit`, and `rollback` methods. This keeps the
//! transaction policy independent from a concrete PostgreSQL driver.

/// Executes a complete schema DDL string in one transaction.
///
/// The caller owns the connection and must provide it outside any existing
/// transaction. A failure while executing or committing attempts a rollback;
/// rollback failure never replaces the original error.
pub fn executeSchema(connection: anytype, ddl: []const u8) !void {
    try connection.begin();
    errdefer connection.rollback() catch {};

    try connection.exec(ddl);
    try connection.commit();
}
