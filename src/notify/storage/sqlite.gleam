import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import notify/core/message.{type Message}
import notify/core/message_json
import notify/core/topic
import notify/delivery
import notify/storage.{type Query, type Storage}
import sqlight.{type Connection}

type Command {
  Save(Message, Subject(Result(Message, storage.Error)))
  Commit(
    Message,
    List(delivery.NewJob),
    Subject(Result(Message, storage.Error)),
  )
  RunQuery(Query, Subject(Result(List(Message), storage.Error)))
  ReleaseDue(Int, Int, Subject(Result(List(Message), storage.Error)))
  CleanupExpired(Int, Subject(Result(Int, storage.Error)))
  Stats(Subject(Result(storage.Stats, storage.Error)))
  Migrate(Subject(Result(Nil, storage.Error)))
  Health(Subject(Result(Nil, storage.Error)))
}

const migration = "
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS schema_migrations (
  version INTEGER PRIMARY KEY,
  applied_at INTEGER NOT NULL DEFAULT (unixepoch())
);

CREATE TABLE IF NOT EXISTS messages (
  position INTEGER PRIMARY KEY AUTOINCREMENT,
  id TEXT NOT NULL UNIQUE,
  topic TEXT NOT NULL,
  time INTEGER NOT NULL,
  expires INTEGER,
  scheduled INTEGER NOT NULL DEFAULT 0,
  sequence_id TEXT,
  payload TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS messages_topic_position
  ON messages(topic, position);
CREATE INDEX IF NOT EXISTS messages_expires
  ON messages(expires) WHERE expires IS NOT NULL;

CREATE TABLE IF NOT EXISTS event_log (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  message_id TEXT NOT NULL,
  event TEXT NOT NULL,
  topic TEXT NOT NULL,
  time INTEGER NOT NULL,
  payload TEXT NOT NULL,
  FOREIGN KEY(message_id) REFERENCES messages(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS event_log_topic_sequence
  ON event_log(topic, sequence);
CREATE INDEX IF NOT EXISTS event_log_message_sequence
  ON event_log(message_id, sequence);

CREATE TABLE IF NOT EXISTS delivery_outbox (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('webpush', 'mobile_relay')),
  endpoint TEXT NOT NULL,
  payload BLOB NOT NULL,
  message_id TEXT NOT NULL,
  topic_hash TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending', 'leased', 'dead_letter')),
  attempts INTEGER NOT NULL DEFAULT 0,
  available_at INTEGER NOT NULL,
  lease_owner TEXT,
  lease_until INTEGER,
  last_error TEXT,
  created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS delivery_outbox_claim
  ON delivery_outbox(kind, state, available_at, lease_until, created_at);

INSERT OR IGNORE INTO schema_migrations(version) VALUES (1);
"

const query_page_size = 256

const supported_schema_version = 2

const schema_recovery = "the source was not modified; for an ntfy database run `notify migrate ntfy --dry-run` and import into a new Notify database, or move this file aside before reset"

const page_query = "
SELECT m.position, m.payload, m.scheduled
FROM messages AS m
WHERE m.position > ?
  AND m.topic IN (SELECT value FROM json_each(?))
  AND COALESCE(json_extract(m.payload, '$._notify_cached'), 1) = 1
  AND (? = 1 OR m.scheduled = 0)
  AND (? = 0 OR m.time >= ?)
  AND (? = 0 OR m.id = ?)
  AND (? = 0 OR json_extract(m.payload, '$.message') = ?)
  AND (? = 0 OR json_extract(m.payload, '$.title') = ?)
  AND (
    ? = 0
    OR COALESCE(json_extract(m.payload, '$.priority'), 3) IN (
      SELECT CAST(value AS INTEGER) FROM json_each(?)
    )
  )
  AND NOT EXISTS (
    SELECT 1
    FROM json_each(?) AS required_tag
    WHERE NOT EXISTS (
      SELECT 1
      FROM json_each(COALESCE(json_extract(m.payload, '$.tags'), '[]')) AS actual_tag
      WHERE actual_tag.value = required_tag.value
    )
  )
  AND (
    ? = 0
    OR m.position = (
      SELECT MAX(latest.position)
      FROM messages AS latest
      WHERE latest.topic = m.topic
        AND latest.scheduled = 0
        AND COALESCE(json_extract(latest.payload, '$._notify_cached'), 1) = 1
    )
  )
ORDER BY m.position ASC
LIMIT ?
"

const after_id_cursor_query = "
SELECT position
FROM messages
WHERE id = ?
  AND topic IN (SELECT value FROM json_each(?))
  AND COALESCE(json_extract(payload, '$._notify_cached'), 1) = 1
  AND (? = 1 OR scheduled = 0)
LIMIT 1
"

pub type Adapter {
  Adapter(storage: Storage, commit: storage.AtomicCommit)
}

pub fn start(path: String) -> Result(Storage, storage.Error) {
  start_adapter(path) |> result.map(fn(adapter) { adapter.storage })
}

/// Creates or upgrades the SQLite schema without leaving an adapter process
/// running. Offline maintenance commands use this before opening their own
/// transaction on the unified Notify database.
pub fn prepare(path: String) -> Result(Nil, storage.Error) {
  use connection <- result.try(
    sqlight.open(path) |> result.map_error(map_error),
  )
  let migrated = migrate(connection)
  let _ = sqlight.close(connection)
  migrated
}

pub fn start_adapter(path: String) -> Result(Adapter, storage.Error) {
  use connection <- result.try(
    sqlight.open(path) |> result.map_error(map_error),
  )
  case migrate(connection) {
    Error(error) -> {
      let _ = sqlight.close(connection)
      Error(error)
    }
    Ok(_) -> start_actor(connection)
  }
}

fn start_actor(connection: Connection) -> Result(Adapter, storage.Error) {
  use started <- result.try(
    actor.new(connection)
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(fn(_) {
      storage.Unavailable("SQLite actor failed to start")
    }),
  )
  let subject = started.data
  let persistent =
    storage.Storage(
      migrate: fn() { process.call(subject, 10_000, Migrate) },
      save: fn(message) {
        process.call(subject, 10_000, fn(reply) { Save(message, reply) })
      },
      query: fn(query) {
        process.call(subject, 10_000, fn(reply) { RunQuery(query, reply) })
      },
      release_due: fn(now, limit) {
        process.call(subject, 10_000, fn(reply) {
          ReleaseDue(now, limit, reply)
        })
      },
      cleanup_expired: fn(now) {
        process.call(subject, 10_000, fn(reply) { CleanupExpired(now, reply) })
      },
      stats: fn() { process.call(subject, 10_000, Stats) },
      health: fn() { process.call(subject, 10_000, Health) },
    )
  Ok(Adapter(
    storage: persistent,
    commit: storage.AtomicCommit(fn(message, jobs) {
      process.call(subject, 10_000, fn(reply) { Commit(message, jobs, reply) })
    }),
  ))
}

fn handle(
  connection: Connection,
  command: Command,
) -> actor.Next(Connection, Command) {
  case command {
    Save(message, reply) -> {
      process.send(reply, save(connection, message))
      actor.continue(connection)
    }
    Commit(message, jobs, reply) -> {
      process.send(reply, commit(connection, message, jobs))
      actor.continue(connection)
    }
    RunQuery(query, reply) -> {
      process.send(reply, run_query(connection, query))
      actor.continue(connection)
    }
    ReleaseDue(now, limit, reply) -> {
      process.send(reply, release_due(connection, now, limit))
      actor.continue(connection)
    }
    CleanupExpired(now, reply) -> {
      process.send(reply, cleanup_expired(connection, now))
      actor.continue(connection)
    }
    Stats(reply) -> {
      process.send(reply, stats(connection))
      actor.continue(connection)
    }
    Migrate(reply) -> {
      process.send(reply, migrate(connection))
      actor.continue(connection)
    }
    Health(reply) -> {
      process.send(reply, health(connection))
      actor.continue(connection)
    }
  }
}

fn migrate(connection: Connection) -> Result(Nil, storage.Error) {
  use _ <- result.try(validate_existing_schema(connection))
  sqlight.exec(migration, connection) |> result.map_error(map_error)
}

fn validate_existing_schema(
  connection: Connection,
) -> Result(Nil, storage.Error) {
  use tables <- result.try(user_tables(connection))
  case tables {
    [] -> Ok(Nil)
    _ ->
      case list.contains(tables, "schema_migrations") {
        False ->
          Error(storage.UnsupportedSchema(
            "unrecognised SQLite schema; " <> schema_recovery,
          ))
        True -> {
          use migration_columns <- result.try(table_columns(
            connection,
            "schema_migrations",
          ))
          use _ <- result.try(
            require_columns("schema_migrations", migration_columns, [
              "version",
              "applied_at",
            ]),
          )
          use version <- result.try(schema_version(connection))
          case version > supported_schema_version {
            True ->
              Error(storage.UnsupportedSchema(
                "SQLite schema version "
                <> int.to_string(version)
                <> " is newer than this Notify binary supports; "
                <> schema_recovery,
              ))
            False ->
              case list.contains(tables, "messages") {
                False -> Ok(Nil)
                True -> {
                  use columns <- result.try(table_columns(
                    connection,
                    "messages",
                  ))
                  require_columns("messages", columns, [
                    "position",
                    "id",
                    "topic",
                    "time",
                    "expires",
                    "scheduled",
                    "sequence_id",
                    "payload",
                  ])
                }
              }
          }
        }
      }
  }
}

fn user_tables(connection: Connection) -> Result(List(String), storage.Error) {
  sqlight.query(
    "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    on: connection,
    with: [],
    expecting: {
      use name <- decode.field(0, decode.string)
      decode.success(name)
    },
  )
  |> result.map_error(map_error)
}

fn table_columns(
  connection: Connection,
  table: String,
) -> Result(List(String), storage.Error) {
  let statement = case table {
    "schema_migrations" -> "PRAGMA table_info(schema_migrations)"
    _ -> "PRAGMA table_info(messages)"
  }
  sqlight.query(statement, on: connection, with: [], expecting: {
    use name <- decode.field(1, decode.string)
    decode.success(name)
  })
  |> result.map_error(map_error)
}

fn schema_version(connection: Connection) -> Result(Int, storage.Error) {
  use versions <- result.try(
    sqlight.query(
      "SELECT COALESCE(MAX(version), 0) FROM schema_migrations",
      on: connection,
      with: [],
      expecting: {
        use version <- decode.field(0, decode.int)
        decode.success(version)
      },
    )
    |> result.map_error(map_error),
  )
  case versions {
    [version] -> Ok(version)
    _ ->
      Error(storage.UnsupportedSchema(
        "schema_migrations has no readable version; " <> schema_recovery,
      ))
  }
}

fn require_columns(
  table: String,
  actual: List(String),
  required: List(String),
) -> Result(Nil, storage.Error) {
  case list.all(required, fn(column) { list.contains(actual, column) }) {
    True -> Ok(Nil)
    False ->
      Error(storage.UnsupportedSchema(
        "SQLite table `"
        <> table
        <> "` does not match the Notify storage contract; "
        <> schema_recovery,
      ))
  }
}

fn save(
  connection: Connection,
  message: Message,
) -> Result(Message, storage.Error) {
  commit(connection, message, [])
}

fn commit(
  connection: Connection,
  message: Message,
  jobs: List(delivery.NewJob),
) -> Result(Message, storage.Error) {
  let payload = message_json.encode_storage(message) |> json.to_string
  use _ <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> result.map_error(map_error),
  )
  let saved = case insert_message(connection, message, payload) {
    Ok(_) -> {
      use _ <- result.try(insert_event(connection, message, payload))
      insert_delivery_jobs(connection, jobs)
    }
    Error(error) -> Error(error)
  }
  case saved {
    Ok(_) ->
      case sqlight.exec("COMMIT", connection) {
        Ok(_) -> Ok(message)
        Error(error) -> {
          let _ = sqlight.exec("ROLLBACK", connection)
          Error(map_error(error))
        }
      }
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", connection)
      Error(error)
    }
  }
}

fn insert_delivery_jobs(
  connection: Connection,
  jobs: List(delivery.NewJob),
) -> Result(Nil, storage.Error) {
  list.try_each(jobs, fn(job) {
    sqlight.query(
      "INSERT INTO delivery_outbox(id, kind, endpoint, payload, message_id, topic_hash, state, attempts, available_at) VALUES (?, ?, ?, ?, ?, ?, 'pending', 0, ?)",
      on: connection,
      with: [
        sqlight.text(job.id),
        sqlight.text(delivery_kind(job.kind)),
        sqlight.text(job.endpoint),
        sqlight.blob(job.payload),
        sqlight.text(job.message_id),
        sqlight.text(job.topic_hash),
        sqlight.int(job.available_at),
      ],
      expecting: decode.dynamic,
    )
    |> result.map(fn(_) { Nil })
    |> result.map_error(map_error)
  })
}

fn delivery_kind(kind: delivery.Kind) -> String {
  case kind {
    delivery.WebPush -> "webpush"
    delivery.MobileRelay -> "mobile_relay"
  }
}

fn insert_message(
  connection: Connection,
  message: Message,
  payload: String,
) -> Result(Nil, storage.Error) {
  sqlight.query(
    "INSERT INTO messages(id, topic, time, expires, scheduled, sequence_id, payload) VALUES (?, ?, ?, ?, ?, ?, ?)",
    on: connection,
    with: [
      sqlight.text(message.id),
      sqlight.text(topic.to_string(message.topic)),
      sqlight.int(message.time),
      sqlight.nullable(sqlight.int, message.expires),
      sqlight.bool(message.scheduled),
      sqlight.nullable(sqlight.text, message.sequence_id),
      sqlight.text(payload),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn release_due(
  connection: Connection,
  now: Int,
  limit: Int,
) -> Result(List(Message), storage.Error) {
  use _ <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> result.map_error(map_error),
  )
  let claimed = do_release_due(connection, now, max(0, limit))
  case claimed {
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", connection)
      Error(error)
    }
    Ok(messages) ->
      case sqlight.exec("COMMIT", connection) {
        Ok(_) -> Ok(messages)
        Error(error) -> {
          let _ = sqlight.exec("ROLLBACK", connection)
          Error(map_error(error))
        }
      }
  }
}

fn do_release_due(
  connection: Connection,
  now: Int,
  limit: Int,
) -> Result(List(Message), storage.Error) {
  use rows <- result.try(
    sqlight.query(
      "SELECT position, payload FROM messages WHERE scheduled = 1 AND time <= ? ORDER BY position ASC LIMIT ?",
      on: connection,
      with: [sqlight.int(now), sqlight.int(limit)],
      expecting: {
        use position <- decode.field(0, decode.int)
        use payload <- decode.field(1, decode.string)
        decode.success(#(position, payload))
      },
    )
    |> result.map_error(map_error),
  )
  list.try_map(rows, fn(row) {
    use decoded <- result.try(
      json.parse(row.1, message_json.decoder())
      |> result.map_error(fn(_) { storage.Corrupt("invalid message payload") }),
    )
    let released = message.Message(..decoded, scheduled: False)
    let payload = message_json.encode_storage(released) |> json.to_string
    use _ <- result.try(
      sqlight.query(
        "UPDATE messages SET scheduled = 0, payload = ? WHERE position = ? AND scheduled = 1",
        on: connection,
        with: [sqlight.text(payload), sqlight.int(row.0)],
        expecting: decode.dynamic,
      )
      |> result.map_error(map_error),
    )
    use _ <- result.try(insert_event(connection, released, payload))
    Ok(released)
  })
}

fn max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}

fn insert_event(
  connection: Connection,
  message: Message,
  payload: String,
) -> Result(Nil, storage.Error) {
  sqlight.query(
    "INSERT INTO event_log(message_id, event, topic, time, payload) VALUES (?, ?, ?, ?, ?)",
    on: connection,
    with: [
      sqlight.text(message.id),
      sqlight.text(message.event |> message.event_to_string),
      sqlight.text(topic.to_string(message.topic)),
      sqlight.int(message.time),
      sqlight.text(payload),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn run_query(
  connection: Connection,
  selection: Query,
) -> Result(List(Message), storage.Error) {
  case selection.since {
    storage.NoneSince -> Ok([])
    _ -> {
      use cursor <- result.try(initial_query_cursor(connection, selection))
      query_pages(connection, selection, cursor, [])
    }
  }
}

fn initial_query_cursor(
  connection: Connection,
  selection: Query,
) -> Result(Int, storage.Error) {
  case selection.since {
    storage.AfterId(id) ->
      sqlight.query(
        after_id_cursor_query,
        on: connection,
        with: [
          sqlight.text(id),
          sqlight.text(json_strings(topic.many_to_strings(selection.topics))),
          sqlight.bool(selection.include_scheduled),
        ],
        expecting: {
          use position <- decode.field(0, decode.int)
          decode.success(position)
        },
      )
      |> result.map(fn(rows) { rows |> list.first |> result.unwrap(0) })
      |> result.map_error(map_error)
    _ -> Ok(0)
  }
}

fn query_pages(
  connection: Connection,
  selection: Query,
  cursor: Int,
  pages: List(List(Message)),
) -> Result(List(Message), storage.Error) {
  use rows <- result.try(
    sqlight.query(
      page_query,
      on: connection,
      with: page_parameters(selection, cursor),
      expecting: {
        use position <- decode.field(0, decode.int)
        use payload <- decode.field(1, decode.string)
        use scheduled <- decode.field(2, decode.int)
        decode.success(#(position, payload, scheduled != 0))
      },
    )
    |> result.map_error(map_error),
  )
  use messages <- result.try(
    list.try_map(rows, fn(row) {
      use decoded <- result.try(
        json.parse(row.1, message_json.decoder())
        |> result.map_error(fn(_) { storage.Corrupt("invalid message payload") }),
      )
      Ok(message.Message(..decoded, scheduled: row.2))
    }),
  )
  let pages = [messages, ..pages]
  case list.length(rows) < query_page_size {
    True -> Ok(pages |> list.reverse |> list.flatten)
    False -> {
      let next_cursor =
        rows
        |> list.last
        |> result.map(fn(row) { row.0 })
        |> result.unwrap(cursor)
      query_pages(connection, selection, next_cursor, pages)
    }
  }
}

fn page_parameters(selection: Query, cursor: Int) -> List(sqlight.Value) {
  let criteria = selection.criteria
  let #(after_time_enabled, after_time) = case selection.since {
    storage.AfterTime(time) -> #(True, time)
    _ -> #(False, 0)
  }
  [
    sqlight.int(cursor),
    sqlight.text(json_strings(topic.many_to_strings(selection.topics))),
    sqlight.bool(selection.include_scheduled),
    sqlight.bool(after_time_enabled),
    sqlight.int(after_time),
    sqlight.bool(is_some(criteria.id)),
    sqlight.text(optional_string(criteria.id)),
    sqlight.bool(is_some(criteria.message)),
    sqlight.text(optional_string(criteria.message)),
    sqlight.bool(is_some(criteria.title)),
    sqlight.text(optional_string(criteria.title)),
    sqlight.bool(criteria.priorities != []),
    sqlight.text(
      json_ints(list.map(criteria.priorities, message.priority_to_int)),
    ),
    sqlight.text(json_strings(criteria.tags)),
    sqlight.bool(selection.since == storage.Latest),
    sqlight.int(query_page_size),
  ]
}

fn json_strings(values: List(String)) -> String {
  json.array(values, json.string) |> json.to_string
}

fn json_ints(values: List(Int)) -> String {
  json.array(values, json.int) |> json.to_string
}

fn is_some(value: Option(a)) -> Bool {
  case value {
    Some(_) -> True
    None -> False
  }
}

fn optional_string(value: Option(String)) -> String {
  case value {
    Some(value) -> value
    None -> ""
  }
}

fn health(connection: Connection) -> Result(Nil, storage.Error) {
  sqlight.query("SELECT 1", on: connection, with: [], expecting: {
    use value <- decode.field(0, decode.int)
    decode.success(value)
  })
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn cleanup_expired(
  connection: Connection,
  now: Int,
) -> Result(Int, storage.Error) {
  use before <- result.try(message_count(connection))
  use _ <- result.try(
    sqlight.query(
      "DELETE FROM messages WHERE (expires IS NOT NULL AND expires <= ?) OR COALESCE(json_extract(payload, '$._notify_cached'), 1) = 0",
      on: connection,
      with: [sqlight.int(now)],
      expecting: decode.dynamic,
    )
    |> result.map_error(map_error),
  )
  use after <- result.try(message_count(connection))
  Ok(before - after)
}

fn message_count(connection: Connection) -> Result(Int, storage.Error) {
  use rows <- result.try(
    sqlight.query(
      "SELECT COUNT(*) FROM messages",
      on: connection,
      with: [],
      expecting: {
        use count <- decode.field(0, decode.int)
        decode.success(count)
      },
    )
    |> result.map_error(map_error),
  )
  case rows {
    [count] -> Ok(count)
    _ -> Error(storage.Corrupt("message count returned no row"))
  }
}

fn stats(connection: Connection) -> Result(storage.Stats, storage.Error) {
  use rows <- result.try(
    sqlight.query(
      "SELECT (SELECT COUNT(*) FROM messages), (SELECT COUNT(*) FROM messages WHERE scheduled = 1), (SELECT COUNT(*) FROM event_log)",
      on: connection,
      with: [],
      expecting: {
        use messages <- decode.field(0, decode.int)
        use scheduled <- decode.field(1, decode.int)
        use events <- decode.field(2, decode.int)
        decode.success(storage.Stats(messages:, scheduled:, events:))
      },
    )
    |> result.map_error(map_error),
  )
  case rows {
    [stats] -> Ok(stats)
    _ -> Error(storage.Corrupt("storage stats returned no row"))
  }
}

fn map_error(error: sqlight.Error) -> storage.Error {
  let sqlight.SqlightError(code:, message:, ..) = error
  case code {
    sqlight.Constraint | sqlight.ConstraintUnique -> storage.Conflict(message)
    sqlight.Corrupt | sqlight.Notadb -> storage.Corrupt(message)
    _ -> storage.Unavailable(message)
  }
}
