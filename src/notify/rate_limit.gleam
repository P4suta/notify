import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result
import postgleam
import postgleam/config.{type Config}
import postgleam/decode
import postgleam/error as pg_error

pub type Decision {
  Allowed(remaining: Int, reset_at: Int)
  Limited(retry_after: Int, reset_at: Int)
}

pub type Error {
  Unavailable(String)
}

pub type Limiter {
  Limiter(
    limit: Int,
    window_seconds: Int,
    check: fn(String, Int) -> Result(Decision, Error),
  )
}

type Window {
  Window(start: Int, count: Int)
}

type MemoryState {
  MemoryState(requests: Int, window_seconds: Int, windows: Dict(String, Window))
}

type MemoryCommand {
  MemoryCheck(String, Int, Subject(Result(Decision, Error)))
}

type PostgresState {
  PostgresState(
    connection: postgleam.Connection,
    requests: Int,
    window_seconds: Int,
  )
}

type PostgresCommand {
  PostgresCheck(String, Int, Subject(Result(Decision, Error)))
}

const postgres_migration = "
CREATE TABLE IF NOT EXISTS notify_rate_limits (
  client_key TEXT NOT NULL,
  window_start BIGINT NOT NULL,
  request_count BIGINT NOT NULL,
  PRIMARY KEY (client_key, window_start)
);
CREATE INDEX IF NOT EXISTS notify_rate_limits_window
  ON notify_rate_limits(window_start);
"

pub fn memory(
  requests requests: Int,
  window_seconds window_seconds: Int,
) -> Result(Limiter, Error) {
  use _ <- result.try(validate_limits(requests, window_seconds))
  use started <- result.try(
    actor.new(MemoryState(requests:, window_seconds:, windows: dict.new()))
    |> actor.on_message(handle_memory)
    |> actor.start
    |> result.map_error(fn(_) {
      Unavailable("in-memory rate limiter failed to start")
    }),
  )
  let subject = started.data
  Ok(
    Limiter(limit: requests, window_seconds:, check: fn(client_key, now) {
      process.call(subject, 5000, fn(reply) {
        MemoryCheck(client_key, now, reply)
      })
    }),
  )
}

pub fn postgres(
  config: Config,
  requests requests: Int,
  window_seconds window_seconds: Int,
) -> Result(Limiter, Error) {
  use _ <- result.try(validate_limits(requests, window_seconds))
  use connection <- result.try(
    postgleam.connect(config) |> result.map_error(map_postgres_error),
  )
  case migrate_postgres(connection) {
    Error(error) -> {
      postgleam.disconnect(connection)
      Error(error)
    }
    Ok(_) -> start_postgres_actor(connection, requests, window_seconds)
  }
}

fn validate_limits(requests: Int, window_seconds: Int) -> Result(Nil, Error) {
  case requests > 0 && window_seconds > 0 {
    True -> Ok(Nil)
    False -> Error(Unavailable("rate limit and window must be positive"))
  }
}

fn handle_memory(
  state: MemoryState,
  command: MemoryCommand,
) -> actor.Next(MemoryState, MemoryCommand) {
  let MemoryCheck(client_key, now, reply) = command
  let window_start = start_of_window(now, state.window_seconds)
  let active_windows =
    dict.filter(state.windows, fn(_, window) { window.start == window_start })
  let count = case dict.get(active_windows, client_key) {
    Ok(window) -> window.count + 1
    Error(_) -> 1
  }
  let updated =
    dict.insert(active_windows, client_key, Window(window_start, count))
  process.send(
    reply,
    Ok(decision(count, state.requests, window_start, state.window_seconds, now)),
  )
  actor.continue(MemoryState(..state, windows: updated))
}

fn start_postgres_actor(
  connection: postgleam.Connection,
  requests: Int,
  window_seconds: Int,
) -> Result(Limiter, Error) {
  use started <- result.try(
    actor.new(PostgresState(connection:, requests:, window_seconds:))
    |> actor.on_message(handle_postgres)
    |> actor.start
    |> result.map_error(fn(_) {
      Unavailable("PostgreSQL rate limiter failed to start")
    }),
  )
  let subject = started.data
  Ok(
    Limiter(limit: requests, window_seconds:, check: fn(client_key, now) {
      process.call(subject, 30_000, fn(reply) {
        PostgresCheck(client_key, now, reply)
      })
    }),
  )
}

fn handle_postgres(
  state: PostgresState,
  command: PostgresCommand,
) -> actor.Next(PostgresState, PostgresCommand) {
  let PostgresCheck(client_key, now, reply) = command
  process.send(reply, check_postgres(state, client_key, now))
  actor.continue(state)
}

fn migrate_postgres(connection: postgleam.Connection) -> Result(Nil, Error) {
  postgleam.transaction(connection, fn(tx) {
    use _ <- result.try(
      postgleam.query(tx, "SELECT pg_advisory_xact_lock($1::bigint)", [
        postgleam.int(7_413_706_846),
      ]),
    )
    use _ <- result.try(postgleam.simple_query(tx, postgres_migration))
    Ok(Nil)
  })
  |> result.map_error(map_postgres_error)
}

fn check_postgres(
  state: PostgresState,
  client_key: String,
  now: Int,
) -> Result(Decision, Error) {
  let window_start = start_of_window(now, state.window_seconds)
  postgleam.transaction(state.connection, fn(tx) {
    use _ <- result.try(
      postgleam.query(
        tx,
        "DELETE FROM notify_rate_limits WHERE client_key = $1 AND window_start < $2",
        [postgleam.text(client_key), postgleam.int(window_start)],
      ),
    )
    use response <- result.try(
      postgleam.query_with(
        tx,
        "INSERT INTO notify_rate_limits(client_key, window_start, request_count) VALUES ($1, $2, 1) ON CONFLICT(client_key, window_start) DO UPDATE SET request_count = notify_rate_limits.request_count + 1 RETURNING request_count",
        [postgleam.text(client_key), postgleam.int(window_start)],
        {
          use count <- decode.element(0, decode.int)
          decode.success(count)
        },
      ),
    )
    let count = response.rows |> list.first |> result.unwrap(state.requests + 1)
    Ok(decision(count, state.requests, window_start, state.window_seconds, now))
  })
  |> result.map_error(map_postgres_error)
}

fn decision(
  count: Int,
  requests: Int,
  window_start: Int,
  window_seconds: Int,
  now: Int,
) -> Decision {
  let reset_at = window_start + window_seconds
  case count <= requests {
    True -> Allowed(remaining: int.max(0, requests - count), reset_at:)
    False -> Limited(retry_after: int.max(1, reset_at - now), reset_at:)
  }
}

fn start_of_window(now: Int, window_seconds: Int) -> Int {
  now - { now % window_seconds }
}

fn map_postgres_error(error: pg_error.Error) -> Error {
  case error {
    pg_error.PgError(fields, _, _) ->
      Unavailable("PostgreSQL " <> fields.code <> ": " <> fields.message)
    pg_error.ConnectionError(detail)
    | pg_error.AuthenticationError(detail)
    | pg_error.EncodeError(detail)
    | pg_error.ProtocolError(detail)
    | pg_error.SocketError(detail)
    | pg_error.DecodeError(detail) -> Unavailable(detail)
    pg_error.TimeoutError -> Unavailable("PostgreSQL request timed out")
  }
}
