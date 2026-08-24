import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
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
  sqlight.exec(migration, connection) |> result.map_error(map_error)
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
    use _ <- result.try(
      sqlight.query(
        "UPDATE messages SET scheduled = 0 WHERE position = ? AND scheduled = 1",
        on: connection,
        with: [sqlight.int(row.0)],
        expecting: decode.dynamic,
      )
      |> result.map_error(map_error),
    )
    use decoded <- result.try(
      json.parse(row.1, message_json.decoder())
      |> result.map_error(fn(_) { storage.Corrupt("invalid message payload") }),
    )
    Ok(message.Message(..decoded, scheduled: False))
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
  use rows <- result.try(
    sqlight.query(
      "SELECT payload, scheduled FROM messages ORDER BY position ASC",
      on: connection,
      with: [],
      expecting: {
        use payload <- decode.field(0, decode.string)
        use scheduled <- decode.field(1, decode.int)
        decode.success(#(payload, scheduled != 0))
      },
    )
    |> result.map_error(map_error),
  )
  use messages <- result.try(
    list.try_map(rows, fn(row) {
      use decoded <- result.try(
        json.parse(row.0, message_json.decoder())
        |> result.map_error(fn(_) { storage.Corrupt("invalid message payload") }),
      )
      Ok(message.Message(..decoded, scheduled: row.1))
    }),
  )
  Ok(storage.apply_query(messages, selection))
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
