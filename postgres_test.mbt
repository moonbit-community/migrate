///|
/// PostgreSQL tests are opt-in and use a separate schema for each test.
fn postgres_test_port() -> Int32? raise {
  guard @env.get_env_var("MIGRATOR_POSTGRES_TEST_PORT") is Some(port) else {
    return None
  }
  Some(@string.parse_int(port))
}

///|
async fn with_postgres_test_schema(
  port : Int32,
  name : String,
  run : async (@pg.Client, String) -> Unit,
) -> Unit {
  @async.with_timeout(15000, () => {
    @async.with_task_group(group => {
      let (client, executor) = @pg.Client::create(
        @pg.Config::Config(
          "127.0.0.1",
          port~,
          user="postgres",
          password="migrator",
          database="postgres",
          ssl_mode=@pg.SslMode::Disable,
          application_name="moonbit-migrator-test",
        ),
      )
      group.spawn_bg(allow_failure=true, () => executor.run())
      defer client.close()
      client.ready()
      let schema = "migrator_\{name}_\{@env.now()}"
      client.batch_execute("CREATE SCHEMA \{schema}")
      defer @async.protect_from_cancel(() => {
        client.batch_execute("DROP SCHEMA \{schema} CASCADE")
      })
      client.batch_execute("SET search_path TO \{schema}")
      run(client, schema)
    })
  })
}

///|
async test "postgres client applies and reverses migrations without losing order" {
  guard postgres_test_port() is Some(port) else { return }
  with_postgres_test_schema(port, "client", (client, _) => {
    let table = "app \"history\" 迁移"
    @migrate.Migrate::ensure_migration_table(
      client,
      table="_moonbit_migrations",
    )
    @migrate.Migrate::record_migration(
      client,
      "other",
      true,
      table="_moonbit_migrations",
    )
    let migrations : Map[String, @migrate.Migration[@pg.Client]] = {
      "z-first": {
        upgrade: db => {
          db.batch_execute(
            "CREATE TABLE migration_values (value INTEGER PRIMARY KEY)",
          )
        },
        downgrade: db => db.batch_execute("DROP TABLE migration_values"),
      },
      "a-second's migration": {
        upgrade: db => {
          db.execute("INSERT INTO migration_values VALUES (2)") |> ignore
        },
        downgrade: db => {
          db.execute("DELETE FROM migration_values WHERE value = 2") |> ignore
        },
      },
    }
    let migrator = @migrate.Migrator(migrations, table~)
    migrator.run(client)
    migrator.run(client)
    assert_eq(@migrate.Migrate::list_migrations(client, table~), [
      "z-first", "a-second's migration",
    ])
    let count : Int32 = client
      .query_one("SELECT count(*)::int4 FROM migration_values")
      .get(0)
    assert_eq(count, 1)
    migrator.revert(client, version="z-first")
    assert_eq(@migrate.Migrate::list_migrations(client, table~), ["z-first"])
    let count : Int32 = client
      .query_one("SELECT count(*)::int4 FROM migration_values")
      .get(0)
    assert_eq(count, 0)
    migrations.remove("a-second's migration")
    migrations["d-replacement"] = {
      upgrade: db => {
        db.execute("INSERT INTO migration_values VALUES (9)") |> ignore
      },
      downgrade: db => {
        db.execute("DELETE FROM migration_values WHERE value = 9") |> ignore
      },
    }
    let replacement = @migrate.Migrator(migrations, table~)
    replacement.run(client)
    assert_eq(@migrate.Migrate::list_migrations(client, table~), [
      "z-first", "d-replacement",
    ])
    let value : Int32 = client
      .query_one("SELECT value FROM migration_values")
      .get(0)
    assert_eq(value, 9)
    replacement.revert(client)
    assert_eq(@migrate.Migrate::list_migrations(client, table~), [])
    replacement.run(client)
    assert_eq(@migrate.Migrate::list_migrations(client, table~), [
      "z-first", "d-replacement",
    ])
    assert_eq(
      @migrate.Migrate::list_migrations(client, table="_moonbit_migrations"),
      ["other"],
    )
  })
}

///|
fn postgres_transaction_migrations(
  succeed : Bool,
) -> Map[String, @migrate.Migration[@pg.Transaction]] {
  {
    "create": {
      upgrade: db => {
        db.batch_execute(
          "CREATE TABLE migration_values (value INTEGER PRIMARY KEY)",
        )
      },
      downgrade: db => db.batch_execute("DROP TABLE migration_values"),
    },
    "insert": {
      upgrade: db => {
        db.execute("INSERT INTO migration_values VALUES (7)") |> ignore
        if !succeed {
          raise TestError::Callback
        }
      },
      downgrade: db => {
        db.execute("DELETE FROM migration_values WHERE value = 7") |> ignore
      },
    },
  }
}

///|
async test "postgres transaction rolls back callbacks and migration records together" {
  guard postgres_test_port() is Some(port) else { return }
  with_postgres_test_schema(port, "transaction", (client, _) => {
    let table = "tx \"history\""
    @migrate.Migrate::ensure_migration_table(client, table~)
    assert_eq(@migrate.Migrate::list_migrations(client, table~), [])
    try
      client.with_transaction(tx => {
        @migrate.Migrator(postgres_transaction_migrations(false), table~).run(
          tx,
        )
      })
    catch {
      TestError::Callback => ()
      error => raise error
    } noraise {
      _ => fail("expected the callback error to stop the migration")
    }
    assert_eq(@migrate.Migrate::list_migrations(client, table~), [])
    let table_exists : Bool = client
      .query_one("SELECT to_regclass('migration_values') IS NOT NULL")
      .get(0)
    assert_false(table_exists)
    let runner = @migrate.Migrator(
      postgres_transaction_migrations(true),
      table~,
    )
    client.with_transaction(tx => {
      runner.run(tx)
      assert_eq(@migrate.Migrate::list_migrations(tx, table~), [
        "create", "insert",
      ])
    })
    let value : Int32 = client
      .query_one("SELECT value FROM migration_values")
      .get(0)
    assert_eq(value, 7)
    client.with_transaction(tx => runner.revert(tx, version="create"))
    assert_eq(@migrate.Migrate::list_migrations(client, table~), ["create"])
    client.with_transaction(tx => runner.revert(tx))
    assert_eq(@migrate.Migrate::list_migrations(client, table~), [])
  })
}

///|
async test "postgres pool transactions preserve execution order and roll back state" {
  guard postgres_test_port() is Some(port) else { return }
  with_postgres_test_schema(port, "pool", (_, schema) => {
    @async.with_task_group(group => {
      let (pool, executor) = @pgpool.Pool::create(
        @pgpool.Config::Config(
          [@pgpool.ConnectionTarget(host="127.0.0.1", port~)],
          user="postgres",
          password="migrator",
          dbname="postgres",
          ssl_mode=@pg.SslMode::Disable,
          application_name="moonbit-migrator-pool-test",
          options="-c search_path=\{schema}",
          pool=@pgpool.PoolConfig(1),
        ),
      )
      group.spawn_bg(allow_failure=true, () => executor.run())
      defer pool.close()
      pool.ready()
      let table = "pool \"history\""
      pool.with_transaction(tx => {
        @migrate.Migrate::ensure_migration_table(tx, table~)
        assert_eq(@migrate.Migrate::list_migrations(tx, table~), [])
        @migrate.Migrate::record_migration(tx, "first", true, table~)
      })
      pool.with_session(session => {
        session.with_transaction(tx => {
          @migrate.Migrate::record_migration(tx, "second", true, table~)
          @migrate.Migrate::record_migration(tx, "second", false, table~)
          assert_eq(@migrate.Migrate::list_migrations(tx, table~), ["first"])
          @migrate.Migrate::record_migration(tx, "second", true, table~)
          assert_eq(@migrate.Migrate::list_migrations(tx, table~), [
            "first", "second",
          ])
        })
      })
      try {
        let _ : Unit = pool.with_transaction(tx => {
          @migrate.Migrate::record_migration(tx, "second", false, table~)
          @migrate.Migrate::record_migration(tx, "third", true, table~)
          raise TestError::Recording
        })
      } catch {
        TestError::Recording => ()
        error => raise error
      } noraise {
        _ => fail("expected the transaction callback to raise")
      }
      pool.with_transaction(tx => {
        assert_eq(@migrate.Migrate::list_migrations(tx, table~), [
          "first", "second",
        ])
      })
    })
  })
}
