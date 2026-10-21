///|
struct MemoryDb {
  records : Array[String]
  calls : Array[String]
  mut reject_record : (String, Bool)?
  mut initialized : String?
}

///|
fn MemoryDb::new(records~ : Array[String] = []) -> MemoryDb {
  {
    records: records.copy(),
    calls: [],
    reject_record: None,
    initialized: None,
  }
}

///|
suberror TestError {
  Callback
  Recording
}

///|
impl @migrate.Migrate for MemoryDb with fn ensure_migration_table(self, table~) {
  self.initialized = Some(table)
}

///|
impl @migrate.Migrate for MemoryDb with fn list_migrations(self, table~) {
  assert_eq(self.initialized, Some(table))
  self.records.copy()
}

///|
async test "cancellation does not mark an interrupted callback as applied" {
  let db = MemoryDb::new()
  let runner : @migrate.Migrator[MemoryDb] = @migrate.Migrator({
    "slow": {
      upgrade: db => {
        db.calls.push("up:slow")
        @async.sleep(1000)
      },
      downgrade: _ => (),
    },
    "later": step("later"),
  })
  let result = @async.with_timeout_opt(10, () => runner.run(db))
  assert_eq(result, None)
  assert_eq(db.calls, ["up:slow"])
  assert_eq(db.records, [])
}

///|
impl @migrate.Migrate for MemoryDb with fn record_migration(
  self,
  version,
  applied,
  table~,
) {
  assert_eq(self.initialized, Some(table))
  if self.reject_record == Some((version, applied)) {
    raise TestError::Recording
  }
  if applied {
    assert_false(self.records.contains(version))
    self.records.push(version)
  } else if self.records.search_by(id => id == version) is Some(index) {
    ignore(self.records.remove(index))
  }
}

///|
fn step(
  id : String,
  upgrade_ok~ : Bool = true,
  downgrade_ok~ : Bool = true,
) -> @migrate.Migration[MemoryDb] {
  {
    upgrade: db => {
      db.calls.push("up:" + id)
      if !upgrade_ok {
        raise TestError::Callback
      }
    },
    downgrade: db => {
      db.calls.push("down:" + id)
      if !downgrade_ok {
        raise TestError::Callback
      }
    },
  }
}

///|
async fn expect_failure(action : async () -> Unit) -> Error {
  try action() catch {
    error if @async.is_being_cancelled() => raise error
    error => error
  } noraise {
    _ => fail("expected the operation to fail")
  }
}

///|
async test "map insertion order defines upgrades, even for unordered IDs" {
  let db = MemoryDb::new()
  let runner = @migrate.Migrator({
    "z": step("z"),
    "10": step("10"),
    "2": step("2"),
  })
  runner.run(db)
  assert_eq(db.calls, ["up:z", "up:10", "up:2"])
  assert_eq(db.records, ["z", "10", "2"])
  runner.run(db)
  assert_eq(db.calls.length(), 3)
}

///|
async test "constructor snapshots map insertion order" {
  let db = MemoryDb::new()
  let migrations = { "first": step("first") }
  let runner = @migrate.Migrator(migrations)
  migrations["first"] = step("replacement")
  migrations["later"] = step("later")
  runner.run(db)
  assert_eq(db.calls, ["up:first"])
  assert_eq(db.records, ["first"])
}

///|
async test "one migrator uses the handle and history supplied to each run" {
  let runner = @migrate.Migrator({
    "first": step("first"),
    "second": step("second"),
  })
  let first = MemoryDb::new(records=["first"])
  let second = MemoryDb::new()
  runner.run(first)
  assert_eq(first.calls, ["up:second"])
  assert_eq(second.records, [])
  runner.run(second)
  assert_eq(second.calls, ["up:first", "up:second"])
  runner.revert(first, version="first")
  assert_eq(first.calls, ["up:second", "down:second"])
  assert_eq(first.records, ["first"])
  assert_eq(second.records, ["first", "second"])
  runner.run(first)
  assert_eq(first.calls, ["up:second", "down:second", "up:second"])
  assert_eq(second.calls, ["up:first", "up:second"])
}

///|
async test "targeted downgrade preserves its target and removes reverted records" {
  let db = MemoryDb::new()
  let runner = @migrate.Migrator({
    "z": step("z"),
    "a": step("a"),
    "middle": step("middle"),
  })
  runner.run(db)
  runner.revert(db, version="z")
  assert_eq(db.calls, ["up:z", "up:a", "up:middle", "down:middle", "down:a"])
  assert_eq(db.records, ["z"])
  runner.revert(db, version="z")
  assert_eq(db.calls.length(), 5)
  runner.run(db)
  assert_eq(db.calls, [
    "up:z", "up:a", "up:middle", "down:middle", "down:a", "up:a", "up:middle",
  ])
}

///|
async test "omitted and None targets revert to the initial state" {
  let db = MemoryDb::new()
  let runner = @migrate.Migrator({ "one": step("one"), "two": step("two") })
  runner.run(db)
  runner.revert(db)
  assert_eq(db.records, [])
  assert_eq(db.calls, ["up:one", "up:two", "down:two", "down:one"])
  runner.revert(db)
  assert_eq(db.calls.length(), 4)
  runner.run(db)
  let version : String? = None
  runner.revert(db, version?)
  assert_eq(db.records, [])
  assert_eq(db.calls.length(), 8)
}

///|
async test "empty migration maps are valid only with no applied history" {
  let db = MemoryDb::new()
  let runner = @migrate.Migrator({})
  runner.run(db)
  runner.revert(db)
  assert_eq(db.records, [])
  let existing = MemoryDb::new(records=["old"])
  let error = expect_failure(() => @migrate.Migrator({}).run(existing))
  assert_true(error is @migrate.MigrationError::MissingMigration("old"))
}

///|
async test "new migrations append after applied history" {
  let db = MemoryDb::new(records=["first"])
  let runner = @migrate.Migrator({
    "first": step("first"),
    "second": step("second"),
    "third": step("third"),
  })
  runner.run(db)
  assert_eq(db.calls, ["up:second", "up:third"])
  assert_eq(db.records, ["first", "second", "third"])
}

///|
async test "deleted or reordered history is rejected before callbacks or writes" {
  for ids in [["a", "c"], ["b", "a", "c"], ["a", "inserted", "b", "c"]] {
    let db = MemoryDb::new(records=["a", "b", "c"])
    let migrations : Map[String, @migrate.Migration[MemoryDb]] = Map([])
    for id in ids {
      migrations[id] = step(id)
    }
    let error = expect_failure(() => @migrate.Migrator(migrations).run(db))
    assert_true(error is @migrate.MigrationError::HistoryMismatch(_, _))
    assert_eq(db.calls, [])
    assert_eq(db.records, ["a", "b", "c"])
  }
}

///|
async test "deleting an applied tail is rejected" {
  let db = MemoryDb::new(records=["a", "b"])
  let error = expect_failure(() => @migrate.Migrator({ "a": step("a") }).run(db))
  assert_true(error is @migrate.MigrationError::MissingMigration("b"))
  assert_eq(db.calls, [])
}

///|
async test "applied history must be a prefix of migration definitions" {
  let db = MemoryDb::new(records=["b"])
  let error = expect_failure(() => {
    @migrate.Migrator({ "a": step("a"), "b": step("b") }).run(db)
  })
  assert_true(error is @migrate.MigrationError::HistoryMismatch("b", "a"))
  assert_eq(db.calls, [])
}

///|
async test "unknown and unapplied downgrade targets do not change records" {
  let db = MemoryDb::new(records=["a"])
  let runner = @migrate.Migrator({
    "a": step("a"),
    "b": step("b"),
    "new": step("new"),
  })
  let unknown = expect_failure(() => runner.revert(db, version="missing"))
  assert_true(unknown is @migrate.MigrationError::UnknownVersion("missing"))
  let pending = expect_failure(() => runner.revert(db, version="b"))
  assert_true(pending is @migrate.MigrationError::TargetNotApplied("b"))
  let new_target = expect_failure(() => runner.revert(db, version="new"))
  assert_true(new_target is @migrate.MigrationError::TargetNotApplied("new"))
  assert_eq(db.calls, [])
  assert_eq(db.records, ["a"])
}

///|
async test "an empty string is an ordinary ID distinct from no target" {
  let db = MemoryDb::new()
  let runner = @migrate.Migrator({ "": step("empty"), "later": step("later") })
  runner.run(db)
  let version = Some("")
  runner.revert(db, version?)
  assert_eq(db.calls, ["up:empty", "up:later", "down:later"])
  assert_eq(db.records, [""])
  runner.revert(db)
  assert_eq(db.records, [])
}

///|
async test "failed upgrade records only successful callbacks and can be retried" {
  let db = MemoryDb::new()
  let migrations = {
    "a": step("a"),
    "b": step("b", upgrade_ok=false),
    "c": step("c"),
  }
  let error = expect_failure(() => @migrate.Migrator(migrations).run(db))
  assert_true(error is TestError::Callback)
  assert_eq(db.calls, ["up:a", "up:b"])
  assert_eq(db.records, ["a"])
  migrations["b"] = step("b")
  @migrate.Migrator(migrations).run(db)
  assert_eq(db.calls, ["up:a", "up:b", "up:b", "up:c"])
}

///|
async test "failed downgrade keeps its applied record and stops before older entries" {
  let db = MemoryDb::new(records=["a", "b", "c"])
  let runner = @migrate.Migrator({
    "a": step("a"),
    "b": step("b", downgrade_ok=false),
    "c": step("c"),
  })
  let error = expect_failure(() => runner.revert(db))
  assert_true(error is TestError::Callback)
  assert_eq(db.calls, ["down:c", "down:b"])
  assert_eq(db.records, ["a", "b"])
}

///|
async test "callback errors propagate without successful bookkeeping" {
  let db = MemoryDb::new()
  let runner = @migrate.Migrator({
    "broken": { upgrade: _ => raise TestError::Callback, downgrade: _ => (), },
  })
  let error = expect_failure(() => runner.run(db))
  assert_true(error is TestError::Callback)
  assert_eq(db.records, [])
}

///|
async test "failed record deletion stops before reverting older migrations" {
  let db = MemoryDb::new(records=["a", "b", "c"])
  db.reject_record = Some(("c", false))
  let runner = @migrate.Migrator({
    "a": step("a"),
    "b": step("b"),
    "c": step("c"),
  })
  let error = expect_failure(() => runner.revert(db))
  assert_true(error is TestError::Recording)
  assert_eq(db.calls, ["down:c"])
  assert_eq(db.records, ["a", "b", "c"])
}

///|
async test "reverted migrations can be removed and replaced" {
  let db = MemoryDb::new()
  let original = @migrate.Migrator({
    "a": step("a"),
    "b": step("b"),
    "c": step("c"),
  })
  original.run(db)
  original.revert(db, version="b")
  assert_eq(db.records, ["a", "b"])
  let replacement = @migrate.Migrator({
    "a": step("a"),
    "b": step("b"),
    "d": step("d"),
  })
  replacement.run(db)
  assert_eq(db.records, ["a", "b", "d"])
  assert_eq(db.calls, ["up:a", "up:b", "up:c", "down:c", "up:d"])
  replacement.revert(db, version="b")
  @migrate.Migrator({ "a": step("a"), "b": step("b") }).run(db)
  assert_eq(db.records, ["a", "b"])
  assert_eq(db.calls, ["up:a", "up:b", "up:c", "down:c", "up:d", "down:d"])
}

///|
async test "bookkeeping failures stop before the next callback" {
  let db = MemoryDb::new()
  db.reject_record = Some(("a", true))
  let error = expect_failure(() => {
    @migrate.Migrator({ "a": step("a"), "b": step("b") }).run(db)
  })
  assert_true(error is TestError::Recording)
  assert_eq(db.calls, ["up:a"])
  assert_eq(db.records, [])
}
