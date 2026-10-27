# migrate

A database migration library for MoonBit, with SQLite and PostgreSQL support.
Write upgrade and downgrade functions to change your database schema or data.
The library tracks applied migrations, runs pending ones, and reverts changes
when requested.

## Usage

Start with an `initial-create` migration whose upgrade creates the initial
application schema. Add later schema changes as subsequent migrations. When
rebuilding a service with a fresh database, run this same migration history to
initialize the schema. Creating the schema separately before running migrations
can conflict with migrations that create or alter the same tables.

Import `moonbit-community/migrate` as `migrate` and
`moonbit-community/sqlite3` as `sqlite3` in `moon.pkg`.

```mbt check
///|
async test "SQLite quick start" {
  let db = @sqlite3.Connection::open_async(":memory:")
  defer db.close()
  let migrator : @migrate.Migrator[@sqlite3.Connection] = @migrate.Migrator({
    "initial-create": {
      upgrade: db => {
        let statement = db.prepare_async(
          "CREATE TABLE users(id INTEGER PRIMARY KEY)",
        )
        defer statement.finalize()
        let _ = statement.step_async()
      },
      downgrade: _ => {
        fail("cannot revert initial-create: preserve schema and data")
      },
    },
    "create_posts": {
      upgrade: db => {
        let statement = db.prepare_async(
          "CREATE TABLE posts(id INTEGER PRIMARY KEY)",
        )
        defer statement.finalize()
        let _ = statement.step_async()
      },
      downgrade: db => {
        let statement = db.prepare_async("DROP TABLE posts")
        defer statement.finalize()
        let _ = statement.step_async()
      },
    },
  })
  migrator.run(db)
  assert_eq(
    @migrate.Migrate::list_migrations(db, table="_moonbit_migrations"),
    ["initial-create", "create_posts"],
  )
  migrator.revert(db, version="initial-create")
  assert_eq(
    @migrate.Migrate::list_migrations(db, table="_moonbit_migrations"),
    ["initial-create"],
  )
}
```

Make the `initial-create` downgrade call `fail("...")` so the migration cannot
be reverted and its tables and data cannot be accidentally dropped by a rollback.
Use `revert(db, version="initial-create")` to undo only later migrations while
keeping the initial schema. An untargeted `revert(db)` undoes later migrations
first, then fails at `initial-create`, leaving it applied.

Map keys are migration IDs. Migrations run in map insertion order.
Use `Migrator(migrations, table="app_migrations")` to choose a migrations table.
The default is `_moonbit_migrations`. The name is a single table identifier.

`run(db)` applies pending migrations. `revert(db, version="id")` reverses later
migrations and keeps the target applied. Omit `version` to attempt reverting
everything; a failing downgrade stops the rollback.
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
