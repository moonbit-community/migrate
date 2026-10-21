///|
pub impl Migrate for @sqlite3.Connection with fn ensure_migration_table(
  self,
  table~,
) {
  let table = quote_migration_table(table)
  let statement = self.prepare_async(
    (
      $|CREATE TABLE IF NOT EXISTS \{table} (
      $|  version TEXT NOT NULL PRIMARY KEY,
      $|  position INTEGER NOT NULL UNIQUE
      $|)
    ),
  )
  defer statement.finalize()
  ignore(statement.step_async())
}

///|
pub impl Migrate for @sqlite3.Connection with fn list_migrations(self, table~) {
  let table = quote_migration_table(table)
  let statement = self.prepare_async(
    "SELECT version FROM \{table} ORDER BY position",
  )
  defer statement.finalize()
  let records = []
  while statement.step_async() is @sqlite3.StepResult::Row {
    let version : String = statement.column(index=0)
    records.push(version)
  }
  records
}

///|
pub impl Migrate for @sqlite3.Connection with fn record_migration(
  self,
  version,
  applied,
  table~,
) {
  let table = quote_migration_table(table)
  let sql = if applied {
    (
      $|INSERT INTO \{table} (version, position)
      $|VALUES (?, (SELECT COALESCE(MAX(position), 0) + 1 FROM \{table}))
    )
  } else {
    "DELETE FROM \{table} WHERE version = ?"
  }
  let statement = self.prepare_async(sql)
  defer statement.finalize()
  statement.bind(index=1, version)
  ignore(statement.step_async())
}
