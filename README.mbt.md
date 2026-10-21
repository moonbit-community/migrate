# migrate

A database migration library for MoonBit, with SQLite and PostgreSQL support.
Write upgrade and downgrade functions to change your database schema or data.
The library tracks applied migrations, runs pending ones, and reverts changes
when requested.

## Usage

Import `moonbit-community/migrate` as `migrate` and
`moonbit-community/sqlite3` as `sqlite3` in `moon.pkg`.

```mbt check
///|
async test "SQLite quick start" {
  let db = @sqlite3.Connection::open_async(":memory:")
  defer db.close()
  let migrator : @migrate.Migrator[@sqlite3.Connection] = @migrate.Migrator({
    "create_users": {
      upgrade: db => {
        let statement = db.prepare_async(
          "CREATE TABLE users(id INTEGER PRIMARY KEY)",
        )
        defer statement.finalize()
        statement.step_async() |> ignore
      },
      downgrade: db => {
        let statement = db.prepare_async("DROP TABLE users")
        defer statement.finalize()
        statement.step_async() |> ignore
      },
    },
  })
  migrator.run(db)
  assert_eq(
    @migrate.Migrate::list_migrations(db, table="_moonbit_migrations"),
    ["create_users"],
  )
  migrator.revert(db)
  assert_eq(
    @migrate.Migrate::list_migrations(db, table="_moonbit_migrations"),
    [],
  )
}
```

Map keys are migration IDs. Migrations run in map insertion order.
Use `Migrator(migrations, table="app_migrations")` to choose a migrations table.
The default is `_moonbit_migrations`. The name is a single table identifier.

`run(db)` applies pending migrations. `revert(db, version="id")` reverses later
migrations and keeps the target applied. Omit `version` to revert everything.
An optional value can be forwarded with `revert(db, version?)`, where `None`
also means revert everything. An empty string is an ordinary ID.

Callbacks return `Unit`. Errors stop execution without updating that step's
applied state. A migrator snapshots its definitions and can be reused with
other database handles of the same type.

## Migration history

The library maintains a migrations table containing only currently applied
migrations, in execution order. Successful upgrades append records, and
successful downgrades remove them.

Applied migrations must remain an unchanged prefix of your definitions. Do not
delete, rename, reorder, or edit them. Reverted migrations can be replaced or
removed once no other database still has them applied. Keeping them in the map
makes the next run apply them again. Validation checks IDs and order.

The caller manages transactions and locks. Run callbacks and bookkeeping in
the same transaction, and serialize migration runs.

## Testing

```sh
moon test --target native
sh scripts/test-postgres.sh
```

The first command runs core, SQLite, and example tests. PostgreSQL tests require
`MIGRATOR_POSTGRES_TEST_PORT`. The script starts a disposable PostgreSQL container,
runs the full suite, and removes the container. Pass `wasm` to test that target.

CI checks formatting, interfaces, and both targets with SQLite and PostgreSQL.
To publish, update the version in `moon.mod` and run `publish-package` on `main`.
It runs the checks, publishes using `MOONCAKES_MOONBIT_COMMUNITY_TOKEN`, and tags
the published commit with `v<version>`.
