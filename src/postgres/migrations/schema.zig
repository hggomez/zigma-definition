//! Entrada pública del modelo de migraciones PostgreSQL.
//!
//! Conserva la API del módulo zigma_postgres_migrations y reúne tres responsabilidades:
//! snapshot.zig describe y serializa el schema, diff.zig compara estados y draft.zig
//! propone SQL Liquibase. Ninguno accede a archivos, procesos ni conexiones.

const snapshot = @import("snapshot.zig");
const diff = @import("diff.zig");
const draft = @import("draft.zig");

pub const snapshot_format_version = snapshot.snapshot_format_version;
pub const dialect = snapshot.dialect;
pub const Column = snapshot.Column;
pub const Key = snapshot.Key;
pub const ForeignKey = snapshot.ForeignKey;
pub const Table = snapshot.Table;
pub const Snapshot = snapshot.Snapshot;
pub const createSchemaSnapshot = snapshot.createSchemaSnapshot;
pub const assertAcceptedSnapshot = snapshot.assertAcceptedSnapshot;
pub const SnapshotError = snapshot.SnapshotError;
pub const parseSnapshot = snapshot.parseSnapshot;
pub const snapshotDigest = snapshot.snapshotDigest;

pub const ChangeKind = diff.ChangeKind;
pub const ChangeSafety = diff.ChangeSafety;
pub const Change = diff.Change;
pub const SchemaDiff = diff.SchemaDiff;
pub const diffSnapshots = diff.diffSnapshots;
pub const inferMigrationName = diff.inferMigrationName;

pub const blocker_marker = draft.blocker_marker;
pub const DraftOptions = draft.DraftOptions;
pub const Draft = draft.Draft;
pub const draftMatchesSnapshots = draft.draftMatchesSnapshots;
pub const draftHasBlockers = draft.draftHasBlockers;
pub const createMigrationDraft = draft.createMigrationDraft;
