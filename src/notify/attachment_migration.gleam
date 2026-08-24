import gleam/option.{None}
import notify/attachment_store.{type Store, type Stored}

pub type Report {
  Report(scanned: Int, migrated: Int, skipped: Int, bytes: Int, dry_run: Bool)
}

pub type Error {
  Source(attachment_store.Error)
  Destination(attachment_store.Error)
  IntegrityMismatch(expected: String, actual: String)
}

/// Copy content-addressed attachments without modifying the source. Newly
/// created destination objects are removed if a later copy fails; objects
/// which existed before this run are never removed.
pub fn run(
  source: Store,
  destination: Store,
  dry_run dry_run: Bool,
) -> Result(Report, Error) {
  case source.list() {
    Error(error) -> Error(Source(error))
    Ok(items) ->
      migrate(
        items,
        source,
        destination,
        dry_run,
        [],
        Report(scanned: 0, migrated: 0, skipped: 0, bytes: 0, dry_run:),
      )
  }
}

fn migrate(
  items: List(Stored),
  source: Store,
  destination: Store,
  dry_run: Bool,
  created: List(String),
  report: Report,
) -> Result(Report, Error) {
  case items {
    [] -> Ok(report)
    [item, ..rest] -> {
      let scanned = report.scanned + 1
      case destination.head(item.key) {
        Ok(existing) ->
          case existing.size == item.size {
            True ->
              migrate(
                rest,
                source,
                destination,
                dry_run,
                created,
                Report(..report, scanned:, skipped: report.skipped + 1),
              )
            False ->
              fail(
                destination,
                created,
                IntegrityMismatch(item.key, existing.key),
              )
          }
        Error(attachment_store.NotFound) ->
          case read_and_verify(source, item) {
            Error(error) -> fail(destination, created, error)
            Ok(data) ->
              case dry_run {
                True ->
                  migrate(
                    rest,
                    source,
                    destination,
                    dry_run,
                    created,
                    Report(
                      ..report,
                      scanned:,
                      migrated: report.migrated + 1,
                      bytes: report.bytes + item.size,
                    ),
                  )
                False ->
                  case
                    destination.put(attachment_store.Upload(
                      data:,
                      expires: item.expires,
                    ))
                  {
                    Error(error) ->
                      fail(destination, created, Destination(error))
                    Ok(stored) ->
                      case stored.key == item.key && stored.size == item.size {
                        False -> {
                          let _ = destination.delete(stored.key)
                          fail(
                            destination,
                            created,
                            IntegrityMismatch(item.key, stored.key),
                          )
                        }
                        True ->
                          migrate(
                            rest,
                            source,
                            destination,
                            dry_run,
                            [stored.key, ..created],
                            Report(
                              ..report,
                              scanned:,
                              migrated: report.migrated + 1,
                              bytes: report.bytes + stored.size,
                            ),
                          )
                      }
                  }
              }
          }
        Error(error) -> fail(destination, created, Destination(error))
      }
    }
  }
}

fn read_and_verify(source: Store, item: Stored) -> Result(BitArray, Error) {
  case source.get(item.key, None) {
    Error(error) -> Error(Source(error))
    Ok(download) -> {
      let actual = attachment_store.content_key(download.data)
      case actual == item.key && download.total_size == item.size {
        True -> Ok(download.data)
        False -> Error(IntegrityMismatch(item.key, actual))
      }
    }
  }
}

fn fail(
  destination: Store,
  created: List(String),
  error: Error,
) -> Result(a, Error) {
  rollback(destination, created)
  Error(error)
}

fn rollback(destination: Store, keys: List(String)) -> Nil {
  case keys {
    [] -> Nil
    [key, ..rest] -> {
      let _ = destination.delete(key)
      rollback(destination, rest)
    }
  }
}
