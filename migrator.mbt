///|
/// Database operations used by the migrator.
///
/// Ensure storage exists before listing or recording migrations. The migrator
/// calls ensure_migration_table at the start of each valid-target run.
///
/// Only applied migrations are stored, in execution order. Recording true
/// appends an ID, and false deletes it after a successful downgrade. Operations
/// receive the same table name, which adapters treat as a single identifier.
///
/// Callers must serialize migration runs. To make callbacks and their records
/// atomic, run the migrator on the same connection inside a caller-owned
/// transaction. This trait does not start transactions or acquire locks.
pub(open) trait Migrate {
  async fn ensure_migration_table(Self, table~ : String) -> Unit
  async fn list_migrations(Self, table~ : String) -> Array[String]
  async fn record_migration(Self, String, Bool, table~ : String) -> Unit
}

///|
/// A migration's two callbacks. Normal completion indicates success.
/// Raised errors stop the run and propagate without marking success.
/// The ID and execution order are supplied by the constructor's Map.
pub(all) struct Migration[T] {
  upgrade : async (T) -> Unit
  downgrade : async (T) -> Unit
}

///|
/// A snapshot of a migration map's insertion order and callbacks.
/// Database handles are supplied separately for each migration run.
struct Migrator[T] {
  migrations : Array[(String, Migration[T])]
  table : String
}

///|
/// Construct a migrator. Later mutations of the input map do not change it.
/// IDs are opaque strings, including the empty string.
/// table selects the migrations table, not the tables changed by callbacks.
pub fn[T] Migrator::Migrator(
  migrations : Map[String, Migration[T]],
  table~ : String = "_moonbit_migrations",
) -> Self[T] {
  { migrations: migrations.iter().to_array(), table, }
}

///|
/// Validate applied history and apply all pending
/// migrations in map insertion order. Already applied migrations are skipped.
pub async fn[T : Migrate] Migrator::run(self : Self[T], db : T) -> Unit {
  let applied = self.prepare(db)
  for index, (version, migration) in self.migrations {
    if index >= applied {
      (migration.upgrade)(db)
      db.record_migration(version, true, table=self.table)
    }
  }
}

///|
/// Revert applied migrations after the target ID, in reverse insertion order.
/// The target remains applied. Omit version or pass None to revert everything.
/// An unknown or currently unapplied target is rejected before callbacks or
/// changes to migration records. The adapter may initialize an empty table.
pub async fn[T : Migrate] Migrator::revert(
  self : Self[T],
  db : T,
  version? : String,
) -> Unit {
  let target = if version is Some(version) {
    let target = self.migrations.search_by(m => m.0 == version)
    guard target is Some(index) else {
      raise MigrationError::UnknownVersion(version)
    }
    index + 1
  } else {
    0
  }
  let applied = self.prepare(db)
  if version is Some(version) && target > applied {
    raise MigrationError::TargetNotApplied(version)
  }
  for index in @range.iter(from=applied - 1, to=target, step=-1, inclusive=true) {
    let (id, migration) = self.migrations[index]
    (migration.downgrade)(db)
    db.record_migration(id, false, table=self.table)
  }
}

///|
fn[T] Migrator::validate(
  self : Self[T],
  records : Array[String],
) -> Int32 raise MigrationError {
  for index, version in records {
    guard self.migrations.get(index) is Some((expected, _)) else {
      raise MigrationError::MissingMigration(version)
    }
    if version != expected {
      raise MigrationError::HistoryMismatch(version, expected)
    }
  }
  records.length()
}

///|
async fn[T : Migrate] Migrator::prepare(self : Self[T], db : T) -> Int32 {
  db.ensure_migration_table(table=self.table)
  self.validate(db.list_migrations(table=self.table))
}
