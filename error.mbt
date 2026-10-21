///|
/// Invalid migration history or downgrade targets.
/// Database errors and errors raised by callbacks propagate to the caller.
pub(all) suberror MigrationError {
  MissingMigration(String)
  HistoryMismatch(String, String)
  UnknownVersion(String)
  TargetNotApplied(String)
} derive(Debug, Eq)

///|
pub extend MigrationError with Debug::{to_repr}

///|
pub extend MigrationError with Eq::{equal, not_equal}
