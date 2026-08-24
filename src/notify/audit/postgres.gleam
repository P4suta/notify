import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import notify/audit.{type Event, type NewEvent, type Page, type Store}
import postgleam
import postgleam/config.{type Config}
import postgleam/decode
import postgleam/error as pg_error

type Command {
  Append(NewEvent, Subject(Result(Event, audit.Error)))
  Page(Option(audit.Cursor), Int, Subject(Result(Page, audit.Error)))
  Health(Subject(Result(Nil, audit.Error)))
}

const migration = "
CREATE TABLE IF NOT EXISTS notify_audit_log (
  sequence BIGSERIAL PRIMARY KEY,
  occurred_at BIGINT NOT NULL CHECK (occurred_at >= 0),
  actor TEXT NOT NULL CHECK (char_length(actor) BETWEEN 1 AND 64),
  action TEXT NOT NULL CHECK (action IN (
    'setup.complete', 'session.login', 'session.logout', 'user.create',
    'user.update', 'user.delete', 'user.password_change', 'token.create',
    'token.revoke', 'acl.change', 'acl.revoke', 'anonymous_access.change',
    'delivery.retry', 'delivery.purge', 'attachment.delete'
  )),
  target TEXT CHECK (target IS NULL OR char_length(target) BETWEEN 1 AND 256),
  outcome TEXT NOT NULL CHECK (outcome IN (
    'attempted', 'succeeded', 'failed', 'denied'
  )),
  status BIGINT CHECK (status IS NULL OR status BETWEEN 100 AND 599),
  client_ip TEXT NOT NULL CHECK (char_length(client_ip) BETWEEN 1 AND 64),
  request_id TEXT NOT NULL CHECK (char_length(request_id) BETWEEN 1 AND 64)
);
CREATE INDEX IF NOT EXISTS notify_audit_log_occurred
  ON notify_audit_log(occurred_at DESC, sequence DESC);
"

pub fn start(config: Config) -> Result(Store, audit.Error) {
  use connection <- result.try(
    postgleam.connect(config) |> result.map_error(map_error),
  )
  case validate_existing_schema(connection) {
    Error(error) -> {
      postgleam.disconnect(connection)
      Error(error)
    }
    Ok(_) ->
      case migrate(connection) {
        Error(error) -> {
          postgleam.disconnect(connection)
          Error(error)
        }
        Ok(_) ->
          case start_actor(connection) {
            Ok(store) -> Ok(store)
            Error(error) -> {
              postgleam.disconnect(connection)
              Error(error)
            }
          }
      }
  }
}

fn validate_existing_schema(
  connection: postgleam.Connection,
) -> Result(Nil, audit.Error) {
  use response <- result.try(
    postgleam.query_with(
      connection,
      "SELECT column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = 'notify_audit_log'",
      [],
      {
        use name <- decode.element(0, decode.text)
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
    response.rows == []
    || list.all(required, fn(name) { list.contains(response.rows, name) })
  {
    True -> Ok(Nil)
    False ->
      Error(audit.Corrupt(
        "PostgreSQL notify_audit_log schema is unsupported; the database was not modified; export required data and use a new schema before reset",
      ))
  }
}

fn migrate(connection: postgleam.Connection) -> Result(Nil, audit.Error) {
  postgleam.transaction(connection, fn(tx) {
    use _ <- result.try(
      postgleam.query(tx, "SELECT pg_advisory_xact_lock($1::bigint)", [
        postgleam.int(7_413_706_847),
      ]),
    )
    use _ <- result.try(postgleam.simple_query(tx, migration))
    Ok(Nil)
  })
  |> result.map_error(map_error)
}

fn start_actor(connection: postgleam.Connection) -> Result(Store, audit.Error) {
  use started <- result.try(
    actor.new(connection)
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(fn(_) {
      audit.Unavailable("PostgreSQL audit actor failed to start")
    }),
  )
  let subject = started.data
  Ok(
    audit.Store(
      append: fn(event) {
        process.call(subject, 30_000, fn(reply) { Append(event, reply) })
      },
      page: fn(after, limit) {
        process.call(subject, 30_000, fn(reply) { Page(after, limit, reply) })
      },
      health: fn() { process.call(subject, 30_000, Health) },
    ),
  )
}

fn handle(
  connection: postgleam.Connection,
  command: Command,
) -> actor.Next(postgleam.Connection, Command) {
  case command {
    Append(event, reply) -> process.send(reply, append(connection, event))
    Page(after, limit, reply) ->
      process.send(reply, page(connection, after, limit))
    Health(reply) -> process.send(reply, health(connection))
  }
  actor.continue(connection)
}

fn append(
  connection: postgleam.Connection,
  event: NewEvent,
) -> Result(Event, audit.Error) {
  use _ <- result.try(audit.validate_event(event))
  use response <- result.try(
    postgleam.query_with(
      connection,
      "INSERT INTO notify_audit_log(occurred_at, actor, action, target, outcome, status, client_ip, request_id) VALUES ($1, $2, $3, $4, $5, $6, $7, $8) RETURNING sequence, occurred_at, actor, action, target, outcome, status, client_ip, request_id",
      [
        postgleam.int(event.occurred_at),
        postgleam.text(event.actor),
        postgleam.text(audit.action_name(event.action)),
        postgleam.nullable(event.target, postgleam.text),
        postgleam.text(audit.outcome_name(event.outcome)),
        postgleam.nullable(event.status, postgleam.int),
        postgleam.text(event.client_ip),
        postgleam.text(event.request_id),
      ],
      event_decoder(),
    )
    |> result.map_error(map_error),
  )
  case response.rows {
    [stored] -> Ok(stored)
    _ -> Error(audit.Corrupt("PostgreSQL audit insert returned no row"))
  }
}

fn page(
  connection: postgleam.Connection,
  after: Option(audit.Cursor),
  limit: Int,
) -> Result(Page, audit.Error) {
  use _ <- result.try(audit.validate_page(after, limit))
  let #(statement, parameters) = case after {
    None -> #(
      "SELECT sequence, occurred_at, actor, action, target, outcome, status, client_ip, request_id FROM notify_audit_log ORDER BY sequence DESC LIMIT $1",
      [postgleam.int(limit + 1)],
    )
    Some(audit.Cursor(sequence)) -> #(
      "SELECT sequence, occurred_at, actor, action, target, outcome, status, client_ip, request_id FROM notify_audit_log WHERE sequence < $1 ORDER BY sequence DESC LIMIT $2",
      [postgleam.int(sequence), postgleam.int(limit + 1)],
    )
  }
  use response <- result.try(
    postgleam.query_with(connection, statement, parameters, event_decoder())
    |> result.map_error(map_error),
  )
  Ok(audit.page_from_rows(response.rows, limit))
}

fn event_decoder() -> decode.RowDecoder(Event) {
  use sequence <- decode.element(0, decode.int)
  use occurred_at <- decode.element(1, decode.int)
  use actor <- decode.element(2, decode.text)
  use action <- decode.element(3, decode_action)
  use target <- decode.element(4, decode.optional(decode.text))
  use outcome <- decode.element(5, decode_outcome)
  use status <- decode.element(6, decode.optional(decode.int))
  use client_ip <- decode.element(7, decode.text)
  use request_id <- decode.element(8, decode.text)
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

fn decode_action(value) {
  use raw <- result.try(decode.text(value))
  audit.action_from_name(raw)
  |> result.map_error(fn(_) { pg_error.DecodeError("invalid audit action") })
}

fn decode_outcome(value) {
  use raw <- result.try(decode.text(value))
  audit.outcome_from_name(raw)
  |> result.map_error(fn(_) { pg_error.DecodeError("invalid audit outcome") })
}

fn health(connection: postgleam.Connection) -> Result(Nil, audit.Error) {
  postgleam.query(connection, "SELECT 1", [])
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn map_error(error: pg_error.Error) -> audit.Error {
  case error {
    pg_error.PgError(fields, _, _) ->
      audit.Unavailable("PostgreSQL " <> fields.code <> ": " <> fields.message)
    pg_error.ConnectionError(detail)
    | pg_error.AuthenticationError(detail)
    | pg_error.EncodeError(detail)
    | pg_error.DecodeError(detail)
    | pg_error.ProtocolError(detail)
    | pg_error.SocketError(detail) -> audit.Unavailable(detail)
    pg_error.TimeoutError -> audit.Unavailable("PostgreSQL query timed out")
  }
}
