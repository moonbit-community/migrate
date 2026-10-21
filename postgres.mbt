///|
fn postgres_create_migrations(table : String) -> String {
  let table = quote_migration_table(table)
  (
    $|CREATE TABLE IF NOT EXISTS \{table} (
    $|  version TEXT PRIMARY KEY,
    $|  position BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE
    $|)
  )
}

///|
fn postgres_record_migration(table : String, applied : Bool) -> String {
  let table = quote_migration_table(table)
  if applied {
    "INSERT INTO \{table} (version) VALUES ($1::text)"
  } else {
    "DELETE FROM \{table} WHERE version = $1::text"
  }
}

///|
pub impl Migrate for @pg.Client with fn ensure_migration_table(self, table~) {
  self.batch_execute(postgres_create_migrations(table))
}

///|
pub impl Migrate for @pg.Client with fn list_migrations(self, table~) {
  let table = quote_migration_table(table)
  self.with_stream("SELECT version FROM \{table} ORDER BY position", stream => {
    stream.collect().map(row => row.get(0))
  })
}

///|
pub impl Migrate for @pg.Client with fn record_migration(
  self,
  version,
  applied,
  table~,
) {
  self.execute(postgres_record_migration(table, applied), params=[
    version as &@pg.ToSql,
  ])
  |> ignore
}

///|
pub impl Migrate for @pg.Transaction with fn ensure_migration_table(
  self,
  table~,
) {
  self.batch_execute(postgres_create_migrations(table))
}

///|
pub impl Migrate for @pg.Transaction with fn list_migrations(self, table~) {
  let table = quote_migration_table(table)
  self.with_stream("SELECT version FROM \{table} ORDER BY position", stream => {
    stream.collect().map(row => row.get(0))
  })
}

///|
pub impl Migrate for @pg.Transaction with fn record_migration(
  self,
  version,
  applied,
  table~,
) {
  self.execute(postgres_record_migration(table, applied), params=[
    version as &@pg.ToSql,
  ])
  |> ignore
}

///|
pub impl Migrate for @pgpool.Transaction with fn ensure_migration_table(
  self,
  table~,
) {
  self.batch_execute(postgres_create_migrations(table))
}

///|
pub impl Migrate for @pgpool.Transaction with fn list_migrations(self, table~) {
  let table = quote_migration_table(table)
  self
  .query_all("SELECT version FROM \{table} ORDER BY position")
  .map(row => row.get(0))
}

///|
pub impl Migrate for @pgpool.Transaction with fn record_migration(
  self,
  version,
  applied,
  table~,
) {
  self.execute(postgres_record_migration(table, applied), params=[
    version as &@pg.ToSql,
  ])
  |> ignore
}
