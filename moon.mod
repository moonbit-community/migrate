name = "moonbit-community/migrate"

version = "0.1.2"

readme = "README.mbt.md"

repository = "https://github.com/moonbit-community/migrate"

license = "Apache-2.0"

keywords = [ "migration", "database", "sql", "sqlite", "postgresql" ]

preferred_target = "native"

description = "Database migrations for MoonBit with SQLite and PostgreSQL support."

import {
  "moonbitlang/async@0.22.5",
  "moonbit-community/postgres@0.1.3",
  "moonbit-community/sqlite3@0.2.3",
}
