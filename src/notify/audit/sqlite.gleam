import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import notify/audit.{type Event, type NewEvent, type Page, type Store}
import sqlight.{type Connection}

type Command {
  Append(NewEvent, Subject(Result(Event, audit.Error)))
  Page(Option(audit.Cursor), Int, Subject(Result(Page, audit.Error)))
  Health(Subject(Result(Nil, audit.Error)))
}

const migration = "
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS audit_log (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  occurred_at INTEGER NOT NULL CHECK (occurred_at >= 0),
  actor TEXT NOT NULL CHECK (length(actor) BETWEEN 1 AND 64),
  action TEXT NOT NULL CHECK (action IN (
    'setup.complete', 'session.login', 'session.logout', 'user.create',
    'user.update', 'user.delete', 'user.password_change', 'token.create',
    'token.revoke', 'acl.change', 'acl.revoke', 'anonymous_access.change',
    'delivery.retry', 'delivery.purge', 'attachment.delete'
  )),
  target TEXT CHECK (target IS NULL OR length(target) BETWEEN 1 AND 256),
  outcome TEXT NOT NULL CHECK (outcome IN (
    'attempted', 'succeeded', 'failed', 'denied'
  )),
  status INTEGER CHECK (status IS NULL OR status BETWEEN 100 AND 599),
  client_ip TEXT NOT NULL CHECK (length(client_ip) BETWEEN 1 AND 64),
  request_id TEXT NOT NULL CHECK (length(request_id) BETWEEN 1 AND 64)
);
CREATE INDEX IF NOT EXISTS audit_log_occurred
  ON audit_log(occurred_at DESC, sequence DESC);
"

pub fn start(path: String) -> Result(Store, audit.Error) {
  use connection <- result.try(
    sqlight.open(path) |> result.map_error(map_error),
  )
  case validate_existing_schema(connection) {
    Error(error) -> {
      let _ = sqlight.close(connection)
      Error(error)
    }
    Ok(_) ->
      case sqlight.exec(migration, connection) {
        Error(error) -> {
          let _ = sqlight.close(connection)
          Error(map_error(error))
        }
        Ok(_) ->
          case start_actor(connection) {
            Ok(store) -> Ok(store)
            Error(error) -> {
              let _ = sqlight.close(connection)
              Error(error)
            }
          }
      }
  }
}

fn validate_existing_schema(
  connection: Connection,
) -> Result(Nil, audit.Error) {
  use columns <- result.try(
    sqlight.query(
      "PRAGMA table_info(audit_log)",
      on: connection,
      with: [],
      expecting: {
        use name <- decode.field(1, decode.string)
        decode.success(name)
      },
    )
    |> result.map_error(map_error),
  )
  let required = [
    "sequence",
    "occurred_at",
    "actor",
    "action",
    "target",
    "outcome",
    "status",
    "client_ip",
    "request_id",
  ]
  case
    columns == []
    || list.all(required, fn(name) { list.contains(columns, name) })
  {
    True -> Ok(Nil)
    False ->
      Error(audit.Corrupt(
        "SQLite audit_log schema is unsupported; the database was not modified; export required data and move the file aside before reset",
      ))
  }
}

fn start_actor(connection: Connection) -> Result(Store, audit.Error) {
  use started <- result.try(
    actor.new(connection)
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(fn(_) {
      audit.Unavailable("SQLite audit actor failed to start")
    }),
  )
  let subject = started.data
  Ok(
    audit.Store(
      append: fn(event) {
        process.call(subject, 10_000, fn(reply) { Append(event, reply) })
      },
      page: fn(after, limit) {
        process.call(subject, 10_000, fn(reply) { Page(after, limit, reply) })
      },
      health: fn() { process.call(subject, 10_000, Health) },
    ),
  )
}

fn handle(
  connection: Connection,
  command: Command,
) -> actor.Next(Connection, Command) {
  case command {
    Append(event, reply) -> process.send(reply, append(connection, event))
    Page(after, limit, reply) ->
      process.send(reply, page(connection, after, limit))
    Health(reply) -> process.send(reply, health(connection))
  }
  actor.continue(connection)
}

fn append(
  connection: Connection,
  event: NewEvent,
) -> Result(Event, audit.Error) {
  use _ <- result.try(audit.validate_event(event))
  use _ <- result.try(
    sqlight.query(
      "INSERT INTO audit_log(occurred_at, actor, action, target, outcome, status, client_ip, request_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      on: connection,
      with: [
        sqlight.int(event.occurred_at),
        sqlight.text(event.actor),
        sqlight.text(audit.action_name(event.action)),
        optional_text(event.target),
        sqlight.text(audit.outcome_name(event.outcome)),
        optional_int(event.status),
        sqlight.text(event.client_ip),
        sqlight.text(event.request_id),
      ],
      expecting: decode.dynamic,
    )
    |> result.map_error(map_error),
  )
  use sequences <- result.try(
    sqlight.query(
      "SELECT last_insert_rowid()",
      on: connection,
      with: [],
      expecting: {
        use sequence <- decode.field(0, decode.int)
        decode.success(sequence)
      },
    )
    |> result.map_error(map_error),
  )
  case sequences {
    [sequence] -> Ok(audit.from_new(sequence, event))
    _ -> Error(audit.Corrupt("SQLite audit sequence was not returned"))
  }
}

fn page(
  connection: Connection,
  after: Option(audit.Cursor),
  limit: Int,
) -> Result(Page, audit.Error) {
  use _ <- result.try(audit.validate_page(after, limit))
  let #(statement, parameters) = case after {
    None -> #(
      "SELECT sequence, occurred_at, actor, action, target, outcome, status, client_ip, request_id FROM audit_log ORDER BY sequence DESC LIMIT ?",
      [sqlight.int(limit + 1)],
    )
    Some(audit.Cursor(sequence)) -> #(
      "SELECT sequence, occurred_at, actor, action, target, outcome, status, client_ip, request_id FROM audit_log WHERE sequence < ? ORDER BY sequence DESC LIMIT ?",
      [sqlight.int(sequence), sqlight.int(limit + 1)],
    )
  }
  use rows <- result.try(
    sqlight.query(
      statement,
      on: connection,
      with: parameters,
      expecting: event_decoder(),
    )
    |> result.map_error(map_error),
  )
  Ok(audit.page_from_rows(rows, limit))
}

fn event_decoder() -> decode.Decoder(Event) {
  use sequence <- decode.field(0, decode.int)
  use occurred_at <- decode.field(1, decode.int)
  use actor <- decode.field(2, decode.string)
  use raw_action <- decode.field(3, decode.string)
  use target <- decode.field(4, decode.optional(decode.string))
  use raw_outcome <- decode.field(5, decode.string)
  use status <- decode.field(6, decode.optional(decode.int))
  use client_ip <- decode.field(7, decode.string)
  use request_id <- decode.field(8, decode.string)
  use action <- decode.then(action_decoder(raw_action))
  use outcome <- decode.then(outcome_decoder(raw_outcome))
  decode.success(audit.Event(
    sequence:,
    occurred_at:,
    actor:,
    action:,
    target:,
    outcome:,
    status:,
    client_ip:,
    request_id:,
  ))
}

fn action_decoder(value: String) -> decode.Decoder(audit.Action) {
  case audit.action_from_name(value) {
    Ok(action) -> decode.success(action)
    Error(_) -> decode.failure(audit.SessionLogin, "known audit action")
  }
}

fn outcome_decoder(value: String) -> decode.Decoder(audit.Outcome) {
  case audit.outcome_from_name(value) {
    Ok(outcome) -> decode.success(outcome)
    Error(_) -> decode.failure(audit.Failed, "known audit outcome")
  }
}

fn optional_text(value: Option(String)) -> sqlight.Value {
  case value {
    None -> sqlight.null()
    Some(value) -> sqlight.text(value)
  }
}

fn optional_int(value: Option(Int)) -> sqlight.Value {
  case value {
    None -> sqlight.null()
    Some(value) -> sqlight.int(value)
  }
}

fn health(connection: Connection) -> Result(Nil, audit.Error) {
  sqlight.query("SELECT 1", on: connection, with: [], expecting: decode.dynamic)
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn map_error(error: sqlight.Error) -> audit.Error {
  let sqlight.SqlightError(message:, ..) = error
  audit.Unavailable(message)
}
