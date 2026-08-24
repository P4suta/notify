import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option}
import gleam/otp/actor
import gleam/result
import gleam/string
import notify/attachment_store.{type Store}
import notify/attachment_store/memory
import postgleam
import postgleam/config.{type Config}
import postgleam/decode
import postgleam/error as pg_error

type State {
  State(connection: postgleam.Connection, max_file: Int, max_total: Int)
}

type Command {
  Put(
    attachment_store.Upload,
    Subject(Result(attachment_store.Stored, attachment_store.Error)),
  )
  Head(String, Subject(Result(attachment_store.Stored, attachment_store.Error)))
  Get(
    String,
    Option(attachment_store.ByteRange),
    Subject(Result(attachment_store.Download, attachment_store.Error)),
  )
  List(Subject(Result(List(attachment_store.Stored), attachment_store.Error)))
  Delete(String, Subject(Result(Nil, attachment_store.Error)))
  Cleanup(Int, Subject(Result(Int, attachment_store.Error)))
  Health(Subject(Result(Nil, attachment_store.Error)))
}

const migration = "
CREATE TABLE IF NOT EXISTS notify_attachments (
  key TEXT PRIMARY KEY,
  data BYTEA NOT NULL,
  size BIGINT NOT NULL,
  expires BIGINT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS notify_attachments_expiry
  ON notify_attachments(expires);
"

pub fn start(
  config: Config,
  max_file_bytes max_file: Int,
  max_total_bytes max_total: Int,
) -> Result(Store, attachment_store.Error) {
  use connection <- result.try(
    postgleam.connect(config) |> result.map_error(map_error),
  )
  case migrate(connection) {
    Error(error) -> {
      postgleam.disconnect(connection)
      Error(error)
    }
    Ok(_) -> start_actor(State(connection:, max_file:, max_total:))
  }
}

fn start_actor(state: State) -> Result(Store, attachment_store.Error) {
  use started <- result.try(
    actor.new(state)
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(fn(_) {
      attachment_store.Unavailable(
        "PostgreSQL attachment actor failed to start",
      )
    }),
  )
  let subject = started.data
  Ok(
    attachment_store.Store(
      put: fn(upload) {
        process.call(subject, 30_000, fn(reply) { Put(upload, reply) })
      },
      head: fn(key) {
        process.call(subject, 30_000, fn(reply) { Head(key, reply) })
      },
      get: fn(key, range) {
        process.call(subject, 30_000, fn(reply) { Get(key, range, reply) })
      },
      list: fn() { process.call(subject, 30_000, List) },
      delete: fn(key) {
        process.call(subject, 30_000, fn(reply) { Delete(key, reply) })
      },
      cleanup: fn(now) {
        process.call(subject, 30_000, fn(reply) { Cleanup(now, reply) })
      },
      health: fn() { process.call(subject, 30_000, Health) },
    ),
  )
}

fn handle(state: State, command: Command) -> actor.Next(State, Command) {
  case command {
    Put(upload, reply) -> process.send(reply, put(state, upload))
    Head(key, reply) -> process.send(reply, head(state.connection, key))
    Get(key, range, reply) ->
      process.send(reply, get(state.connection, key, range))
    List(reply) -> process.send(reply, list_objects(state.connection))
    Delete(key, reply) -> process.send(reply, delete(state.connection, key))
    Cleanup(now, reply) -> process.send(reply, cleanup(state.connection, now))
    Health(reply) -> process.send(reply, health(state.connection))
  }
  actor.continue(state)
}

fn migrate(
  connection: postgleam.Connection,
) -> Result(Nil, attachment_store.Error) {
  postgleam.transaction(connection, fn(tx) {
    use _ <- result.try(
      postgleam.query(tx, "SELECT pg_advisory_xact_lock($1::bigint)", [
        postgleam.int(7_413_706_843),
      ]),
    )
    use _ <- result.try(postgleam.simple_query(tx, migration))
    Ok(Nil)
  })
  |> result.map_error(map_error)
}

fn put(
  state: State,
  upload: attachment_store.Upload,
) -> Result(attachment_store.Stored, attachment_store.Error) {
  let size = bit_array.byte_size(upload.data)
  case size > state.max_file {
    True -> Error(attachment_store.TooLarge(state.max_file, size))
    False -> {
      let key = attachment_store.content_key(upload.data)
      postgleam.transaction(state.connection, fn(tx) {
        use _ <- result.try(
          postgleam.query(tx, "SELECT pg_advisory_xact_lock($1::bigint)", [
            postgleam.int(7_413_706_844),
          ]),
        )
        use existing <- result.try(
          postgleam.query_with(
            tx,
            "SELECT size, expires FROM notify_attachments WHERE key = $1 FOR UPDATE",
            [postgleam.text(key)],
            {
              use size <- decode.element(0, decode.int)
              use expires <- decode.element(1, decode.int)
              decode.success(#(size, expires))
            },
          ),
        )
        case existing.rows {
          [row] -> {
            let expires = max(row.1, upload.expires)
            use _ <- result.try(
              postgleam.query(
                tx,
                "UPDATE notify_attachments SET expires = $1 WHERE key = $2",
                [postgleam.int(expires), postgleam.text(key)],
              ),
            )
            Ok(attachment_store.Stored(key:, size: row.0, expires:))
          }
          [] -> {
            use total <- result.try(
              postgleam.query_one(
                tx,
                "SELECT COALESCE(SUM(size), 0)::bigint FROM notify_attachments",
                [],
                {
                  use total <- decode.element(0, decode.int)
                  decode.success(total)
                },
              ),
            )
            case total + size > state.max_total {
              True -> Error(postgleam.query_error("attachment quota exceeded"))
              False -> {
                use _ <- result.try(
                  postgleam.query(
                    tx,
                    "INSERT INTO notify_attachments(key, data, size, expires) VALUES ($1, $2, $3, $4)",
                    [
                      postgleam.text(key),
                      postgleam.bytea(upload.data),
                      postgleam.int(size),
                      postgleam.int(upload.expires),
                    ],
                  ),
                )
                Ok(attachment_store.Stored(key:, size:, expires: upload.expires))
              }
            }
          }
          _ -> Error(postgleam.query_error("duplicate attachment key"))
        }
      })
      |> result.map_error(fn(error) {
        case error {
          pg_error.ConnectionError("attachment quota exceeded") ->
            attachment_store.QuotaExceeded(state.max_total)
          other -> map_error(other)
        }
      })
    }
  }
}

fn head(
  connection: postgleam.Connection,
  key: String,
) -> Result(attachment_store.Stored, attachment_store.Error) {
  use _ <- result.try(validate_key(key))
  use response <- result.try(
    postgleam.query_with(
      connection,
      "SELECT size, expires FROM notify_attachments WHERE key = $1",
      [postgleam.text(key)],
      {
        use size <- decode.element(0, decode.int)
        use expires <- decode.element(1, decode.int)
        decode.success(attachment_store.Stored(key:, size:, expires:))
      },
    )
    |> result.map_error(map_error),
  )
  response.rows |> one_or_not_found
}

fn get(
  connection: postgleam.Connection,
  key: String,
  range: Option(attachment_store.ByteRange),
) -> Result(attachment_store.Download, attachment_store.Error) {
  use _ <- result.try(validate_key(key))
  use response <- result.try(
    postgleam.query_with(
      connection,
      "SELECT data FROM notify_attachments WHERE key = $1",
      [postgleam.text(key)],
      {
        use data <- decode.element(0, decode.bytea)
        decode.success(data)
      },
    )
    |> result.map_error(map_error),
  )
  use data <- result.try(response.rows |> one_or_not_found)
  memory.download(data, range)
}

fn delete(
  connection: postgleam.Connection,
  key: String,
) -> Result(Nil, attachment_store.Error) {
  use _ <- result.try(validate_key(key))
  postgleam.query(connection, "DELETE FROM notify_attachments WHERE key = $1", [
    postgleam.text(key),
  ])
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn list_objects(
  connection: postgleam.Connection,
) -> Result(List(attachment_store.Stored), attachment_store.Error) {
  postgleam.query_with(
    connection,
    "SELECT key, size, expires FROM notify_attachments ORDER BY key",
    [],
    {
      use key <- decode.element(0, decode.text)
      use size <- decode.element(1, decode.int)
      use expires <- decode.element(2, decode.int)
      decode.success(attachment_store.Stored(key:, size:, expires:))
    },
  )
  |> result.map(fn(response) { response.rows })
  |> result.map_error(map_error)
}

fn cleanup(
  connection: postgleam.Connection,
  now: Int,
) -> Result(Int, attachment_store.Error) {
  postgleam.query_one(
    connection,
    "WITH deleted AS (DELETE FROM notify_attachments WHERE expires <= $1 RETURNING 1) SELECT COUNT(*)::bigint FROM deleted",
    [postgleam.int(now)],
    {
      use count <- decode.element(0, decode.int)
      decode.success(count)
    },
  )
  |> result.map_error(map_error)
}

fn health(
  connection: postgleam.Connection,
) -> Result(Nil, attachment_store.Error) {
  postgleam.query(connection, "SELECT 1", [])
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn validate_key(key: String) -> Result(Nil, attachment_store.Error) {
  let hexadecimal = "0123456789abcdef"
  case
    string.length(key) == 64
    && key
    |> string.to_graphemes
    |> list.all(fn(character) { string.contains(hexadecimal, character) })
  {
    True -> Ok(Nil)
    False -> Error(attachment_store.NotFound)
  }
}

fn one_or_not_found(values: List(a)) -> Result(a, attachment_store.Error) {
  case values {
    [value] -> Ok(value)
    [] -> Error(attachment_store.NotFound)
    _ ->
      Error(attachment_store.Unavailable(
        "attachment query returned duplicate rows",
      ))
  }
}

fn map_error(error: pg_error.Error) -> attachment_store.Error {
  case error {
    pg_error.PgError(fields, _, _) ->
      attachment_store.Unavailable(
        "PostgreSQL " <> fields.code <> ": " <> fields.message,
      )
    pg_error.ConnectionError(detail)
    | pg_error.AuthenticationError(detail)
    | pg_error.EncodeError(detail)
    | pg_error.DecodeError(detail)
    | pg_error.ProtocolError(detail)
    | pg_error.SocketError(detail) -> attachment_store.Unavailable(detail)
    pg_error.TimeoutError ->
      attachment_store.Unavailable("PostgreSQL request timed out")
  }
}

fn max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}
