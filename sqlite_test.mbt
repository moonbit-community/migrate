///|
async fn sqlite_execute(db : @sqlite3.Connection, sql : String) -> Unit {
  let statement = db.prepare_async(sql)
  defer statement.finalize()
  let result = statement.step_async()
  assert_true(result is @sqlite3.StepResult::Done(_))
}

///|
async fn sqlite_scalar(db : @sqlite3.Connection, sql : String) -> Int64 {
  let statement = db.prepare_async(sql)
  defer statement.finalize()
  assert_eq(statement.step_async(), @sqlite3.StepResult::Row)
  statement.column(index=0)
}

///|
async fn sqlite_transaction(
  db : @sqlite3.Connection,
  run : async () -> Unit,
) -> Unit {
  sqlite_execute(db, "BEGIN IMMEDIATE")
  errdefer @async.protect_from_cancel(() => sqlite_execute(db, "ROLLBACK"))
  run()
  sqlite_execute(db, "COMMIT")
}

///|
fn sqlite_steps(
  succeed~ : Bool = true,
) -> Map[String, @migrate.Migration[@sqlite3.Connection]] {
  {
    "z-create": {
      upgrade: db => {
        sqlite_execute(
          db, "CREATE TABLE migration_values(value INTEGER PRIMARY KEY)",
        )
      },
      downgrade: db => sqlite_execute(db, "DROP TABLE migration_values"),
    },
    "a-insert": {
      upgrade: db => {
        sqlite_execute(db, "INSERT INTO migration_values VALUES (7)")
        if !succeed {
          raise TestError::Callback
        }
      },
      downgrade: db => {
        sqlite_execute(db, "DELETE FROM migration_values WHERE value = 7")
      },
    },
  }
}

///|
async test "sqlite stores only applied IDs in execution order" {
  let db = @sqlite3.Connection::open_async(":memory:")
  defer db.close()
  @migrate.Migrate::ensure_migration_table(db, table="_moonbit_migrations")
  assert_eq(
    @migrate.Migrate::list_migrations(db, table="_moonbit_migrations"),
    [],
  )
  @migrate.Migrate::record_migration(
    db,
    "z-last",
    true,
    table="_moonbit_migrations",
  )
  @migrate.Migrate::record_migration(
    db,
    "a-first's 迁移",
    true,
    table="_moonbit_migrations",
  )
  assert_eq(
    @migrate.Migrate::list_migrations(db, table="_moonbit_migrations"),
    ["z-last", "a-first's 迁移"],
  )
  @migrate.Migrate::record_migration(
    db,
    "z-last",
    false,
    table="_moonbit_migrations",
  )
  assert_eq(
    @migrate.Migrate::list_migrations(db, table="_moonbit_migrations"),
    ["a-first's 迁移"],
  )
  @migrate.Migrate::record_migration(
    db,
    "z-last",
    true,
    table="_moonbit_migrations",
  )
  assert_eq(
    @migrate.Migrate::list_migrations(db, table="_moonbit_migrations"),
    ["a-first's 迁移", "z-last"],
  )
}

///|
async test "sqlite migrates idempotently and reverses to a target or the initial state" {
  let db = @sqlite3.Connection::open_async(":memory:")
  defer db.close()
  let runner = @migrate.Migrator(sqlite_steps())
  runner.run(db)
  runner.run(db)
  assert_eq(sqlite_scalar(db, "SELECT count(*) FROM migration_values"), 1L)
  runner.revert(db, version="z-create")
  assert_eq(sqlite_scalar(db, "SELECT count(*) FROM migration_values"), 0L)
  assert_eq(
    @migrate.Migrate::list_migrations(db, table="_moonbit_migrations"),
    ["z-create"],
  )
  runner.revert(db)
  assert_eq(
    sqlite_scalar(
      db, "SELECT count(*) FROM sqlite_master WHERE name = 'migration_values'",
    ),
    0L,
  )
  assert_eq(
    @migrate.Migrate::list_migrations(db, table="_moonbit_migrations"),
    [],
  )
  runner.run(db)
  assert_eq(sqlite_scalar(db, "SELECT value FROM migration_values"), 7L)
}

///|
async test "sqlite caller transaction rolls back callback effects and migration records together" {
  let db = @sqlite3.Connection::open_async(":memory:")
  defer db.close()
  let error = expect_failure(() => {
    sqlite_transaction(db, () => {
      @migrate.Migrator(sqlite_steps(succeed=false)).run(db)
    })
  })
  assert_true(error is TestError::Callback)
  assert_eq(
    sqlite_scalar(
      db, "SELECT count(*) FROM sqlite_master WHERE name IN ('migration_values', '_moonbit_migrations')",
    ),
    0L,
  )
  sqlite_transaction(db, () => @migrate.Migrator(sqlite_steps()).run(db))
  assert_eq(
    @migrate.Migrate::list_migrations(db, table="_moonbit_migrations"),
    ["z-create", "a-insert"],
  )
}

///|
async test "sqlite propagates recording errors and releases statements on failure" {
  let db = @sqlite3.Connection::open_async(":memory:")
  defer db.close()
  @migrate.Migrate::ensure_migration_table(db, table="_moonbit_migrations")
  @migrate.Migrate::list_migrations(db, table="_moonbit_migrations") |> ignore
  sqlite_execute(
    db, "CREATE TRIGGER reject_registration BEFORE INSERT ON _moonbit_migrations BEGIN SELECT RAISE(ABORT, 'registry rejected'); END",
  )
  let error = expect_failure(() => {
    @migrate.Migrate::record_migration(
      db,
      "first",
      true,
      table="_moonbit_migrations",
    )
  })
  assert_true(
    error is @sqlite3.SqliteError(code=Constraint, msg="registry rejected", ..),
  )
  sqlite_execute(db, "DROP TRIGGER reject_registration")
  @migrate.Migrate::record_migration(
    db,
    "first",
    true,
    table="_moonbit_migrations",
  )
  assert_eq(
    @migrate.Migrate::list_migrations(db, table="_moonbit_migrations"),
    ["first"],
  )
}

///|
async test "sqlite custom tables isolate history and allow replacing a reverted migration" {
  let db = @sqlite3.Connection::open_async(":memory:")
  defer db.close()
  @migrate.Migrate::ensure_migration_table(db, table="_moonbit_migrations")
  @migrate.Migrate::record_migration(
    db,
    "other",
    true,
    table="_moonbit_migrations",
  )
  let table = "app \"history\" 迁移"
  let migrations = sqlite_steps()
  let original = @migrate.Migrator(migrations, table~)
  original.run(db)
  original.revert(db, version="z-create")
  migrations.remove("a-insert")
  migrations["d-insert"] = {
    upgrade: db => sqlite_execute(db, "INSERT INTO migration_values VALUES (9)"),
    downgrade: db => {
      sqlite_execute(db, "DELETE FROM migration_values WHERE value = 9")
    },
  }
  let replacement = @migrate.Migrator(migrations, table~)
  replacement.run(db)
  assert_eq(@migrate.Migrate::list_migrations(db, table~), [
    "z-create", "d-insert",
  ])
  assert_eq(sqlite_scalar(db, "SELECT value FROM migration_values"), 9L)
  replacement.revert(db)
  assert_eq(@migrate.Migrate::list_migrations(db, table~), [])
  assert_eq(
    @migrate.Migrate::list_migrations(db, table="_moonbit_migrations"),
    ["other"],
  )
}
