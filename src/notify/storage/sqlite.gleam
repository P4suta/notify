import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
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
  HasAttachment(topic.Topic, String, Subject(Result(Bool, storage.Error)))
  ReleaseDue(Int, Int, Subject(Result(List(Message), storage.Error)))
  CleanupExpired(Int, Subject(Result(Int, storage.Error)))
  Stats(Subject(Result(storage.Stats, storage.Error)))
  Migrate(Subject(Result(Nil, storage.Error)))
  Health(Subject(Result(Nil, storage.Error)))
}

type CommitCommand {
  LaneCommit(
    Message,
    List(delivery.NewJob),
    Subject(Result(Message, storage.Error)),
  )
  LaneHealth(Subject(Result(Nil, storage.Error)))
}

type CommitState {
  CommitState(subject: Subject(CommitCommand), connection: Connection)
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
CREATE INDEX IF NOT EXISTS messages_due
  ON messages(time, position) WHERE scheduled = 1;
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
CREATE INDEX IF NOT EXISTS delivery_outbox_claim_pending
  ON delivery_outbox(kind, endpoint, available_at, created_at, id)
  WHERE state = 'pending';
CREATE INDEX IF NOT EXISTS delivery_outbox_claim_leased
  ON delivery_outbox(kind, endpoint, lease_until, created_at, id)
  WHERE state = 'leased';

INSERT OR IGNORE INTO schema_migrations(version) VALUES (1);
"

const query_page_size = 256

const commit_batch_size = 64

const commit_batch_job_limit = 512

const commit_batch_byte_limit = 4_194_304

const commit_batch_wait_milliseconds = 1

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
    Ok(_) ->
      case path == ":memory:" {
        True -> start_actor(connection)
        False -> start_split_adapter(path, connection)
      }
  }
}

fn start_actor(connection: Connection) -> Result(Adapter, storage.Error) {
  use subject <- result.try(start_subject(connection))
  Ok(adapter(subject, None))
}

fn start_split_adapter(
  path: String,
  read_connection: Connection,
) -> Result(Adapter, storage.Error) {
  case sqlight.open(path) {
    Error(error) -> {
      let _ = sqlight.close(read_connection)
      Error(map_error(error))
    }
    Ok(commit_connection) ->
      case
        sqlight.exec(
          "PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=5000;",
          commit_connection,
        )
      {
        Error(error) -> {
          let _ = sqlight.close(read_connection)
          let _ = sqlight.close(commit_connection)
          Error(map_error(error))
        }
        Ok(_) ->
          case start_subject(read_connection) {
            Error(error) -> {
              let _ = sqlight.close(read_connection)
              let _ = sqlight.close(commit_connection)
              Error(error)
            }
            Ok(subject) ->
              case start_commit_subject(commit_connection) {
                Error(error) -> {
                  let _ = sqlight.close(commit_connection)
                  Error(error)
                }
                Ok(commit_subject) -> Ok(adapter(subject, Some(commit_subject)))
              }
          }
      }
  }
}

fn start_subject(
  connection: Connection,
) -> Result(Subject(Command), storage.Error) {
  use started <- result.try(
    actor.new(connection)
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(fn(_) {
      storage.Unavailable("SQLite actor failed to start")
    }),
  )
  Ok(started.data)
}

fn start_commit_subject(
  connection: Connection,
) -> Result(Subject(CommitCommand), storage.Error) {
  actor.new_with_initialiser(1000, fn(subject) {
    Ok(
      actor.initialised(CommitState(subject:, connection:))
      |> actor.returning(subject),
    )
  })
  |> actor.on_message(handle_commit_lane)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(fn(_) {
    storage.Unavailable("SQLite commit actor failed to start")
  })
}

fn adapter(
  subject: Subject(Command),
  commit_subject: Option(Subject(CommitCommand)),
) -> Adapter {
  let persistent =
    storage.Storage(
      migrate: fn() { process.call(subject, 10_000, Migrate) },
      save: fn(message) {
        case commit_subject {
          None ->
            process.call(subject, 10_000, fn(reply) { Save(message, reply) })
          Some(commit_subject) ->
            process.call(commit_subject, 10_000, fn(reply) {
              LaneCommit(message, [], reply)
            })
        }
      },
      query: fn(query) {
        process.call(subject, 10_000, fn(reply) { RunQuery(query, reply) })
      },
      has_attachment: fn(topic, key) {
        process.call(subject, 10_000, fn(reply) {
          HasAttachment(topic, key, reply)
        })
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
      health: fn() {
        use _ <- result.try(process.call(subject, 10_000, Health))
        case commit_subject {
          None -> Ok(Nil)
          Some(commit_subject) ->
            process.call(commit_subject, 10_000, LaneHealth)
        }
      },
    )
  Adapter(
    storage: persistent,
    commit: storage.AtomicCommit(fn(message, jobs) {
      case commit_subject {
        None ->
          process.call(subject, 10_000, fn(reply) {
            Commit(message, jobs, reply)
          })
        Some(commit_subject) ->
          process.call(commit_subject, 10_000, fn(reply) {
            LaneCommit(message, jobs, reply)
          })
      }
    }),
  )
}

fn handle_commit_lane(
  state: CommitState,
  command: CommitCommand,
) -> actor.Next(CommitState, CommitCommand) {
  let commands =
    collect_commit_commands(
      state.subject,
      commit_batch_size - 1,
      commit_batch_wait_milliseconds,
      [command],
    )
  actor.continue(run_commit_commands(state, commands))
}

fn collect_commit_commands(
  subject: Subject(CommitCommand),
  remaining: Int,
  wait_milliseconds: Int,
  accumulated: List(CommitCommand),
) -> List(CommitCommand) {
  case remaining > 0 {
    False -> list.reverse(accumulated)
    True ->
      case process.receive(subject, wait_milliseconds) {
        Ok(command) ->
          collect_commit_commands(subject, remaining - 1, 0, [
            command,
            ..accumulated
          ])
        Error(_) -> list.reverse(accumulated)
      }
  }
}

fn run_commit_commands(
  state: CommitState,
  commands: List(CommitCommand),
) -> CommitState {
  case commands {
    [] -> state
    [LaneHealth(reply), ..remaining] -> {
      process.send(reply, health(state.connection))
      run_commit_commands(state, remaining)
    }
    [LaneCommit(message, jobs, reply), ..remaining] -> {
      case commit_cost(message, jobs) {
        Error(error) -> {
          process.send(reply, Error(error))
          run_commit_commands(state, remaining)
        }
        Ok(_) -> {
          let #(batch, remaining) = take_commit_prefix(commands, 0, 2, [])
          let outcome = commit_batch(state.connection, batch)
          send_commit_results(batch, outcome)
          run_commit_commands(state, remaining)
        }
      }
    }
  }
}

fn take_commit_prefix(
  commands: List(CommitCommand),
  job_count: Int,
  encoded_bytes: Int,
  accumulated: List(CommitCommand),
) -> #(List(CommitCommand), List(CommitCommand)) {
  case commands {
    [LaneCommit(message, jobs, reply), ..remaining] -> {
      let candidate_jobs = list.length(jobs)
      let candidate_bytes = commit_encoded_bytes(message, jobs)
      let separator_bytes = case accumulated {
        [] -> 0
        _ -> 1
      }
      case
        candidate_jobs <= commit_batch_job_limit
        && candidate_bytes + 2 <= commit_batch_byte_limit
        && job_count + candidate_jobs <= commit_batch_job_limit
        && encoded_bytes + separator_bytes + candidate_bytes
        <= commit_batch_byte_limit
        && list.length(accumulated) < commit_batch_size
      {
        True ->
          take_commit_prefix(
            remaining,
            job_count + candidate_jobs,
            encoded_bytes + separator_bytes + candidate_bytes,
            [LaneCommit(message, jobs, reply), ..accumulated],
          )
        False -> #(list.reverse(accumulated), commands)
      }
    }
    _ -> #(list.reverse(accumulated), commands)
  }
}

fn commit_cost(
  message: Message,
  jobs: List(delivery.NewJob),
) -> Result(Nil, storage.Error) {
  case
    list.length(jobs) <= commit_batch_job_limit
    && commit_encoded_bytes(message, jobs) + 2 <= commit_batch_byte_limit
  {
    True -> Ok(Nil)
    False ->
      Error(storage.Unavailable(
        "commit item exceeds the 512-job or 4 MiB batch limit",
      ))
  }
}

fn commit_encoded_bytes(message: Message, jobs: List(delivery.NewJob)) -> Int {
  commit_json(message, jobs) |> json.to_string |> string.byte_size
}

// Use the same encoded envelope as PostgreSQL for the shared 4 MiB bound.
// In particular, delivery payloads are measured after base64 expansion.
fn commit_json(message: Message, jobs: List(delivery.NewJob)) -> json.Json {
  json.object([
    #("id", json.string(message.id)),
    #("topic", json.string(topic.to_string(message.topic))),
    #("time", json.int(message.time)),
    #("expires", json.nullable(message.expires, json.int)),
    #("scheduled", json.bool(message.scheduled)),
    #("sequence_id", json.nullable(message.sequence_id, json.string)),
    #("event", json.string(message.event |> message.event_to_string)),
    #("payload", message_json.encode_storage(message)),
    #("jobs", json.array(jobs, delivery_job_json)),
  ])
}

fn delivery_job_json(job: delivery.NewJob) -> json.Json {
  json.object([
    #("id", json.string(job.id)),
    #("kind", json.string(delivery_kind(job.kind))),
    #("endpoint", json.string(job.endpoint)),
    #("payload_base64", json.string(bit_array.base64_encode(job.payload, True))),
    #("message_id", json.string(job.message_id)),
    #("topic_hash", json.string(job.topic_hash)),
    #("available_at", json.int(job.available_at)),
  ])
}

fn commit_batch(
  connection: Connection,
  commands: List(CommitCommand),
) -> Result(List(Result(Message, storage.Error)), storage.Error) {
  use _ <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> result.map_error(map_error),
  )
  case commit_batch_items(connection, commands, []) {
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", connection)
      Error(error)
    }
    Ok(outcomes) ->
      case sqlight.exec("COMMIT", connection) {
        Ok(_) -> Ok(outcomes)
        Error(error) -> {
          let _ = sqlight.exec("ROLLBACK", connection)
          Error(map_error(error))
        }
      }
  }
}

fn commit_batch_items(
  connection: Connection,
  commands: List(CommitCommand),
  accumulated: List(Result(Message, storage.Error)),
) -> Result(List(Result(Message, storage.Error)), storage.Error) {
  case commands {
    [] -> Ok(list.reverse(accumulated))
    [LaneCommit(message, jobs, _), ..remaining] -> {
      use _ <- result.try(
        sqlight.exec("SAVEPOINT notify_commit_item", connection)
        |> result.map_error(map_error),
      )
      let outcome = commit_item(connection, message, jobs)
      case outcome {
        Ok(message) -> {
          use _ <- result.try(release_commit_savepoint(connection))
          commit_batch_items(connection, remaining, [Ok(message), ..accumulated])
        }
        Error(error) -> {
          case error {
            storage.Conflict(_) -> {
              use _ <- result.try(rollback_commit_savepoint(connection))
              commit_batch_items(connection, remaining, [
                Error(error),
                ..accumulated
              ])
            }
            _ -> {
              let _ = rollback_commit_savepoint(connection)
              Error(error)
            }
          }
        }
      }
    }
    [LaneHealth(_), ..] ->
      Error(storage.Unavailable("invalid SQLite commit batch"))
  }
}

fn commit_item(
  connection: Connection,
  message: Message,
  jobs: List(delivery.NewJob),
) -> Result(Message, storage.Error) {
  let payload = message_json.encode_storage(message) |> json.to_string
  use _ <- result.try(insert_message(connection, message, payload))
  use _ <- result.try(insert_event(connection, message, payload))
  use _ <- result.try(insert_delivery_jobs(connection, jobs))
  Ok(message)
}

fn release_commit_savepoint(
  connection: Connection,
) -> Result(Nil, storage.Error) {
  sqlight.exec("RELEASE SAVEPOINT notify_commit_item", connection)
  |> result.map_error(map_error)
}

fn rollback_commit_savepoint(
  connection: Connection,
) -> Result(Nil, storage.Error) {
  use _ <- result.try(
    sqlight.exec("ROLLBACK TO SAVEPOINT notify_commit_item", connection)
    |> result.map_error(map_error),
  )
  release_commit_savepoint(connection)
}

fn send_commit_results(
  commands: List(CommitCommand),
  outcome: Result(List(Result(Message, storage.Error)), storage.Error),
) -> Nil {
  case outcome {
    Error(error) ->
      list.each(commands, fn(command) {
        let assert LaneCommit(_, _, reply) = command
        process.send(reply, Error(error))
      })
    Ok(outcomes) -> send_commit_rows(commands, outcomes)
  }
}

fn send_commit_rows(
  commands: List(CommitCommand),
  outcomes: List(Result(Message, storage.Error)),
) -> Nil {
  case commands, outcomes {
    [], [] -> Nil
    [LaneCommit(_, _, reply), ..commands], [outcome, ..outcomes] -> {
      process.send(reply, outcome)
      send_commit_rows(commands, outcomes)
    }
    _, _ ->
      list.each(commands, fn(command) {
        let assert LaneCommit(_, _, reply) = command
        process.send(
          reply,
          Error(storage.Unavailable(
            "SQLite commit actor returned an invalid batch",
          )),
        )
      })
  }
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
    HasAttachment(topic, key, reply) -> {
      process.send(reply, has_attachment(connection, topic, key))
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
  case limit > 0 {
    False -> Ok([])
    True -> {
      use rows <- result.try(
        sqlight.query(
          "SELECT EXISTS(SELECT 1 FROM messages WHERE scheduled = 1 AND time <= ? LIMIT 1)",
          on: connection,
          with: [sqlight.int(now)],
          expecting: {
            use found <- decode.field(0, decode.int)
            decode.success(found != 0)
          },
        )
        |> result.map_error(map_error),
      )
      case rows {
        [True] -> release_due_transaction(connection, now, limit)
        [False] -> Ok([])
        _ -> Error(storage.Corrupt("scheduled existence query returned no row"))
      }
    }
  }
}

fn release_due_transaction(
  connection: Connection,
  now: Int,
  limit: Int,
) -> Result(List(Message), storage.Error) {
  use _ <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> result.map_error(map_error),
  )
  let claimed = do_release_due(connection, now, limit)
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

fn has_attachment(
  connection: Connection,
  attached_topic: topic.Topic,
  key: String,
) -> Result(Bool, storage.Error) {
  let path = "/file/" <> topic.to_string(attached_topic) <> "/" <> key
  use rows <- result.try(
    sqlight.query(
      "SELECT EXISTS(SELECT 1 FROM messages WHERE topic = ? AND (instr(COALESCE(json_extract(payload, '$.attachment.url'), ''), ? || '/') > 0 OR substr(COALESCE(json_extract(payload, '$.attachment.url'), ''), -length(?)) = ?))",
      on: connection,
      with: [
        sqlight.text(topic.to_string(attached_topic)),
        sqlight.text(path),
        sqlight.text(path),
        sqlight.text(path),
      ],
      expecting: {
        use found <- decode.field(0, decode.int)
        decode.success(found != 0)
      },
    )
    |> result.map_error(map_error),
  )
  case rows {
    [found] -> Ok(found)
    _ -> Error(storage.Corrupt("attachment reference query returned no row"))
  }
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
