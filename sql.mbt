///|
/// Quote one SQL identifier for both supported backends. Table names are data,
/// including embedded quotes and dots, rather than SQL fragments or paths.
fn quote_migration_table(table : String) -> String {
  let escaped = table.replace_all(old="\"", new="\"\"")
  "\"\{escaped}\""
}
