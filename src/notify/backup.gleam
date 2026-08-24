pub type Error {
  SourceNotFound
  DestinationExists
  SamePath
  NotNotifyDatabase
  Unavailable(String)
}

/// Creates a consistent online snapshot of a file-backed Notify SQLite
/// database. The destination is never overwritten.
pub fn create_sqlite(
  source: String,
  destination: String,
) -> Result(Nil, Error) {
  sqlite_backup(source, destination) |> map_result
}

/// Verifies SQLite integrity and the minimum Notify schema identity.
pub fn verify_sqlite(path: String) -> Result(Nil, Error) {
  sqlite_verify(path) |> map_result
}

/// Restores a verified snapshot to a new path. Existing files are deliberately
/// rejected so recovery cannot silently destroy a database.
pub fn restore_sqlite(
  snapshot: String,
  destination: String,
) -> Result(Nil, Error) {
  sqlite_restore(snapshot, destination) |> map_result
}

pub fn error_message(error: Error) -> String {
  case error {
    SourceNotFound -> "source database does not exist"
    DestinationExists ->
      "destination already exists; choose a new path and replace the old database only after verification"
    SamePath -> "source and destination must be different paths"
    NotNotifyDatabase ->
      "database integrity or Notify schema verification failed"
    Unavailable(detail) -> "SQLite backup operation failed: " <> detail
  }
}

fn map_result(result: Result(Nil, String)) -> Result(Nil, Error) {
  case result {
    Ok(value) -> Ok(value)
    Error("source_not_found") -> Error(SourceNotFound)
    Error("destination_exists") -> Error(DestinationExists)
    Error("same_path") -> Error(SamePath)
    Error("not_notify_database") -> Error(NotNotifyDatabase)
    Error(detail) -> Error(Unavailable(detail))
  }
}

@external(erlang, "notify_ffi", "sqlite_backup")
fn sqlite_backup(source: String, destination: String) -> Result(Nil, String)

@external(erlang, "notify_ffi", "sqlite_verify")
fn sqlite_verify(path: String) -> Result(Nil, String)

@external(erlang, "notify_ffi", "sqlite_restore")
fn sqlite_restore(snapshot: String, destination: String) -> Result(Nil, String)
