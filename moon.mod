name = "moonbit-community/migrate"

version = "0.1.0"

readme = "README.mbt.md"

repository = "https://github.com/moonbit-community/migrate"

license = "Apache-2.0"

keywords = [ "migration", "sqlite", "postgresql" ]

preferred_target = "native"

description = "Database migrations for MoonBit with SQLite and PostgreSQL support."

import {
  "moonbitlang/async@0.22.5",
  "moonbitlang/x@0.5.6",
  "moonbit-community/postgres@0.1.2",
  "moonbit-community/sqlite3@0.2.3",
}
