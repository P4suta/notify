import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import notify/attachment_store.{type Store}
import notify/attachment_store/memory
import notify/dispatch_pool
import postgleam
import postgleam/config.{type Config}
import postgleam/decode
import postgleam/error as pg_error

type State {
  State(
    config: Config,
    connection: postgleam.Connection,
    reconnect: Bool,
    uploads: List(Pending),
    max_file: Int,
    max_total: Int,
  )
}

type Pending {
  Pending(
    id: String,
    started_at: Int,
    size: Int,
    hasher: attachment_store.Hasher,
  )
}

type ReadState {
  ReadState(config: Config, connection: postgleam.Connection, reconnect: Bool)
}

type Command {
  Begin(
    attachment_store.BeginUpload,
    Subject(Result(attachment_store.UploadHandle, attachment_store.Error)),
  )
  Write(
    attachment_store.UploadHandle,
    BitArray,
    Subject(Result(attachment_store.Progress, attachment_store.Error)),
  )
  Finish(
    attachment_store.UploadHandle,
    Subject(Result(attachment_store.Stored, attachment_store.Error)),
  )
  Abort(
    attachment_store.UploadHandle,
    Subject(Result(Nil, attachment_store.Error)),
  )
  Put(
    attachment_store.Upload,
    Subject(Result(attachment_store.Stored, attachment_store.Error)),
  )
  Delete(String, Subject(Result(Nil, attachment_store.Error)))
  Cleanup(Int, Subject(Result(Int, attachment_store.Error)))
}

type ReadCommand {
  Head(String, Subject(Result(attachment_store.Stored, attachment_store.Error)))
  Get(
    String,
    Option(attachment_store.ByteRange),
    Subject(Result(attachment_store.Download, attachment_store.Error)),
  )
  ReadRange(String, Int, Int, Subject(Result(BitArray, attachment_store.Error)))
  List(Subject(Result(List(attachment_store.Stored), attachment_store.Error)))
  Page(
    Option(String),
    Int,
    Subject(
      Result(
        attachment_store.Page(attachment_store.Stored),
        attachment_store.Error,
      ),
    ),
  )
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

CREATE TABLE IF NOT EXISTS notify_attachment_chunks (
  key TEXT NOT NULL REFERENCES notify_attachments(key) ON DELETE CASCADE,
  byte_offset BIGINT NOT NULL,
  data BYTEA NOT NULL,
  PRIMARY KEY (key, byte_offset)
);

CREATE TABLE IF NOT EXISTS notify_attachment_uploads (
  id TEXT PRIMARY KEY,
  expires BIGINT NOT NULL,
  size BIGINT NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS notify_attachment_upload_chunks (
  upload_id TEXT NOT NULL REFERENCES notify_attachment_uploads(id) ON DELETE CASCADE,
  byte_offset BIGINT NOT NULL,
  data BYTEA NOT NULL,
  PRIMARY KEY (upload_id, byte_offset)
);
CREATE INDEX IF NOT EXISTS notify_attachment_uploads_created
  ON notify_attachment_uploads(created_at);
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
    Ok(_) ->
      start_actor(State(
        config:,
        connection:,
        reconnect: False,
        uploads: [],
        max_file:,
        max_total:,
      ))
  }
}

fn start_actor(state: State) -> Result(Store, attachment_store.Error) {
  use read_pool <- result.try(start_read_pool(state.config))
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
      begin: fn(upload) {
        process.call(subject, 30_000, fn(reply) { Begin(upload, reply) })
      },
      write: fn(handle, chunk) {
        process.call(subject, 30_000, fn(reply) { Write(handle, chunk, reply) })
      },
      finish: fn(handle) {
        process.call(subject, 30_000, fn(reply) { Finish(handle, reply) })
      },
      abort: fn(handle) {
        process.call(subject, 30_000, fn(reply) { Abort(handle, reply) })
      },
      put: fn(upload) {
        process.call(subject, 30_000, fn(reply) { Put(upload, reply) })
      },
      head: fn(key) {
        call_read(read_pool, 30_000, fn(reply) { Head(key, reply) })
      },
      get: fn(key, range) {
        call_read(read_pool, 30_000, fn(reply) { Get(key, range, reply) })
      },
      open: fn(key, range) {
        use metadata <- result.try(
          call_read(read_pool, 30_000, fn(reply) { Head(key, reply) }),
        )
        use bounds <- result.try(attachment_store.download_bounds(
          metadata.size,
          range,
        ))
        Ok(
          attachment_store.open_reader(
            metadata.size,
            bounds.0,
            bounds.1,
            fn(offset, length) {
              call_read(read_pool, 30_000, fn(reply) {
                ReadRange(key, offset, length, reply)
              })
            },
            fn() { Nil },
          ),
        )
      },
      list: fn() { call_read(read_pool, 30_000, List) },
      page: fn(after, limit) {
        call_read(read_pool, 30_000, fn(reply) { Page(after, limit, reply) })
      },
      delete: fn(key) {
        process.call(subject, 30_000, fn(reply) { Delete(key, reply) })
      },
      cleanup: fn(now) {
        process.call(subject, 30_000, fn(reply) { Cleanup(now, reply) })
      },
      health: fn() { call_read(read_pool, 30_000, Health) },
    ),
  )
}

fn start_read_pool(
  config: Config,
) -> Result(dispatch_pool.Pool(ReadCommand), attachment_store.Error) {
  dispatch_pool.start(
    4,
    fn() {
      use connection <- result.try(
        postgleam.connect(config) |> result.map_error(map_error),
      )
      actor.new(ReadState(config:, connection:, reconnect: False))
      |> actor.on_message(handle_read)
      |> actor.start
      |> result.map(fn(started) { started.data })
      |> result.map_error(fn(_) {
        postgleam.disconnect(connection)
        attachment_store.Unavailable(
          "PostgreSQL attachment read worker failed to start",
        )
      })
    },
    fn() {
      attachment_store.Unavailable(
        "PostgreSQL attachment read pool failed to start",
      )
    },
  )
}

fn call_read(
  pool: dispatch_pool.Pool(ReadCommand),
  timeout: Int,
  command: fn(Subject(Result(value, attachment_store.Error))) -> ReadCommand,
) -> Result(value, attachment_store.Error) {
  let reply = process.new_subject()
  dispatch_pool.send(pool, command(reply))
  case process.receive(reply, timeout) {
    Ok(outcome) -> outcome
    Error(_) ->
      Error(attachment_store.Unavailable("attachment read worker timed out"))
  }
}

fn handle(state: State, command: Command) -> actor.Next(State, Command) {
  case ready_connection(state) {
    Error(error) -> reject_command(state, command, error)
    Ok(ready) -> handle_ready(ready, command)
  }
}

fn handle_ready(state: State, command: Command) -> actor.Next(State, Command) {
  case command {
    Begin(upload, reply) -> {
      let #(next, response) = begin(state, upload, 8)
      respond(next, reply, response)
    }
    Write(handle, chunk, reply) -> {
      let #(next, response) = write(state, handle, chunk)
      respond(next, reply, response)
    }
    Finish(handle, reply) -> {
      let #(next, response) = finish(state, handle)
      respond(next, reply, response)
    }
    Abort(handle, reply) -> {
      let #(next, response) = abort(state, handle)
      respond(next, reply, response)
    }
    Put(upload, reply) -> respond(state, reply, put(state, upload))
    Delete(key, reply) -> respond(state, reply, delete(state.connection, key))
    Cleanup(now, reply) -> {
      let next =
        State(
          ..state,
          uploads: list.filter(state.uploads, fn(upload) {
            upload.started_at > now - 3600
          }),
        )
      respond(next, reply, cleanup(state.connection, now))
    }
  }
}

fn respond(
  state: State,
  reply: Subject(Result(value, attachment_store.Error)),
  outcome: Result(value, attachment_store.Error),
) -> actor.Next(State, Command) {
  process.send(reply, outcome)
  actor.continue(case outcome {
    Error(attachment_store.Unavailable(_)) -> State(..state, reconnect: True)
    _ -> state
  })
}

fn reject_command(
  state: State,
  command: Command,
  error: attachment_store.Error,
) -> actor.Next(State, Command) {
  case command {
    Begin(_, reply) -> process.send(reply, Error(error))
    Write(_, _, reply) -> process.send(reply, Error(error))
    Finish(_, reply) -> process.send(reply, Error(error))
    Abort(_, reply) -> process.send(reply, Error(error))
    Put(_, reply) -> process.send(reply, Error(error))
    Delete(_, reply) -> process.send(reply, Error(error))
    Cleanup(_, reply) -> process.send(reply, Error(error))
  }
  actor.continue(state)
}

fn handle_read(
  state: ReadState,
  command: ReadCommand,
) -> actor.Next(ReadState, ReadCommand) {
  case ready_read_connection(state) {
    Error(error) -> {
      reject_read(command, error)
      actor.continue(ReadState(..state, reconnect: True))
    }
    Ok(ready) -> actor.continue(handle_ready_read(ready, command))
  }
}

fn handle_ready_read(state: ReadState, command: ReadCommand) -> ReadState {
  case command {
    Head(key, reply) -> read_response(state, reply, head(state.connection, key))
    Get(key, range, reply) ->
      read_response(state, reply, get(state.connection, key, range))
    ReadRange(key, offset, length, reply) ->
      read_response(
        state,
        reply,
        read_range(state.connection, key, offset, length),
      )
    List(reply) -> read_response(state, reply, list_objects(state.connection))
    Page(after, limit, reply) ->
      read_response(state, reply, page_objects(state.connection, after, limit))
    Health(reply) -> read_response(state, reply, health(state.connection))
  }
}

fn read_response(
  state: ReadState,
  reply: Subject(Result(value, attachment_store.Error)),
  outcome: Result(value, attachment_store.Error),
) -> ReadState {
  process.send(reply, outcome)
  case outcome {
    Error(attachment_store.Unavailable(_)) ->
      ReadState(..state, reconnect: True)
    _ -> state
  }
}

fn reject_read(command: ReadCommand, error: attachment_store.Error) -> Nil {
  case command {
    Head(_, reply) -> {
      process.send(reply, Error(error))
      Nil
    }
    Get(_, _, reply) -> {
      process.send(reply, Error(error))
      Nil
    }
    ReadRange(_, _, _, reply) -> {
      process.send(reply, Error(error))
      Nil
    }
    List(reply) -> {
      process.send(reply, Error(error))
      Nil
    }
    Page(_, _, reply) -> {
      process.send(reply, Error(error))
      Nil
    }
    Health(reply) -> {
      process.send(reply, Error(error))
      Nil
    }
  }
}

fn ready_read_connection(
  state: ReadState,
) -> Result(ReadState, attachment_store.Error) {
  case state.reconnect {
    False -> Ok(state)
    True ->
      case postgleam.connect(state.config) {
        Error(error) -> Error(map_error(error))
        Ok(connection) -> {
          postgleam.disconnect(state.connection)
          Ok(ReadState(..state, connection:, reconnect: False))
        }
      }
  }
}

fn ready_connection(state: State) -> Result(State, attachment_store.Error) {
  case state.reconnect {
    False -> Ok(state)
    True ->
      case postgleam.connect(state.config) {
        Error(error) -> Error(map_error(error))
        Ok(connection) -> {
          postgleam.disconnect(state.connection)
          Ok(State(..state, connection:, reconnect: False))
        }
      }
  }
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

fn begin(
  state: State,
  upload: attachment_store.BeginUpload,
  attempts: Int,
) -> #(State, Result(attachment_store.UploadHandle, attachment_store.Error)) {
  case attempts <= 0 {
    True -> #(
      state,
      Error(attachment_store.Unavailable("could not allocate upload ID")),
    )
    False -> {
      let id = attachment_store.new_upload_id()
      case
        postgleam.query(
          state.connection,
          "INSERT INTO notify_attachment_uploads(id, expires, size) VALUES ($1, $2, 0)",
          [postgleam.text(id), postgleam.int(upload.expires)],
        )
      {
        Ok(_) -> #(
          State(..state, uploads: [
            Pending(
              id:,
              started_at: unix_seconds(),
              size: 0,
              hasher: attachment_store.new_hasher(),
            ),
            ..state.uploads
          ]),
          Ok(attachment_store.UploadHandle(id:)),
        )
        Error(pg_error.PgError(fields, _, _)) ->
          case fields.code {
            "23505" -> begin(state, upload, attempts - 1)
            _ -> #(
              state,
              Error(attachment_store.Unavailable(
                "PostgreSQL " <> fields.code <> ": " <> fields.message,
              )),
            )
          }
        Error(error) -> #(state, Error(map_error(error)))
      }
    }
  }
}

fn write(
  state: State,
  handle: attachment_store.UploadHandle,
  chunk: BitArray,
) -> #(State, Result(attachment_store.Progress, attachment_store.Error)) {
  let attachment_store.UploadHandle(id) = handle
  case find_upload(state.uploads, id) {
    None -> #(state, Error(attachment_store.NotFound))
    Some(upload) -> {
      let actual = upload.size + bit_array.byte_size(chunk)
      case actual > state.max_file {
        True -> {
          let _ = abort_upload(state.connection, id)
          #(
            remove_upload(state, id),
            Error(attachment_store.TooLarge(state.max_file, actual)),
          )
        }
        False ->
          case
            persist_chunks(state.connection, id, upload.size, chunk, actual)
          {
            Error(error) -> {
              let _ = abort_upload(state.connection, id)
              #(remove_upload(state, id), Error(error))
            }
            Ok(_) -> {
              let updated =
                Pending(
                  ..upload,
                  size: actual,
                  hasher: attachment_store.hash_chunk(upload.hasher, chunk),
                )
              #(
                State(..state, uploads: replace_upload(state.uploads, updated)),
                Ok(attachment_store.Progress(bytes_written: actual)),
              )
            }
          }
      }
    }
  }
}

fn persist_chunks(
  connection: postgleam.Connection,
  id: String,
  previous_size: Int,
  chunk: BitArray,
  actual_size: Int,
) -> Result(Nil, attachment_store.Error) {
  postgleam.transaction(connection, fn(tx) {
    use stored_size <- result.try(
      postgleam.query_one(
        tx,
        "SELECT size FROM notify_attachment_uploads WHERE id = $1 FOR UPDATE",
        [postgleam.text(id)],
        {
          use size <- decode.element(0, decode.int)
          decode.success(size)
        },
      ),
    )
    case stored_size == previous_size {
      False -> Error(postgleam.query_error("attachment upload state conflict"))
      True -> {
        use _ <- result.try(insert_chunks(
          tx,
          id,
          chunk,
          source_offset: 0,
          target_offset: previous_size,
        ))
        use _ <- result.try(
          postgleam.query(
            tx,
            "UPDATE notify_attachment_uploads SET size = $1 WHERE id = $2",
            [postgleam.int(actual_size), postgleam.text(id)],
          ),
        )
        Ok(Nil)
      }
    }
  })
  |> result.map_error(map_error)
}

fn insert_chunks(
  connection: postgleam.Connection,
  id: String,
  data: BitArray,
  source_offset source_offset: Int,
  target_offset target_offset: Int,
) -> Result(Nil, pg_error.Error) {
  let total = bit_array.byte_size(data)
  case source_offset >= total {
    True -> Ok(Nil)
    False -> {
      let length = min(1_048_576, total - source_offset)
      use chunk <- result.try(
        bit_array.slice(data, at: source_offset, take: length)
        |> result.map_error(fn(_) {
          postgleam.query_error("invalid attachment chunk")
        }),
      )
      use _ <- result.try(
        postgleam.query(
          connection,
          "INSERT INTO notify_attachment_upload_chunks(upload_id, byte_offset, data) VALUES ($1, $2, $3)",
          [
            postgleam.text(id),
            postgleam.int(target_offset),
            postgleam.bytea(chunk),
          ],
        ),
      )
      insert_chunks(
        connection,
        id,
        data,
        source_offset: source_offset + length,
        target_offset: target_offset + length,
      )
    }
  }
}

fn finish(
  state: State,
  handle: attachment_store.UploadHandle,
) -> #(State, Result(attachment_store.Stored, attachment_store.Error)) {
  let attachment_store.UploadHandle(id) = handle
  case find_upload(state.uploads, id) {
    None -> #(state, Error(attachment_store.NotFound))
    Some(upload) -> {
      let next = remove_upload(state, id)
      let key = attachment_store.finish_hash(upload.hasher)
      case promote_upload(state, id, key, upload.size) {
        Ok(stored) -> #(next, Ok(stored))
        Error(error) -> {
          let _ = abort_upload(state.connection, id)
          #(next, Error(error))
        }
      }
    }
  }
}

fn promote_upload(
  state: State,
  id: String,
  key: String,
  expected_size: Int,
) -> Result(attachment_store.Stored, attachment_store.Error) {
  postgleam.transaction(state.connection, fn(tx) {
    use _ <- result.try(
      postgleam.query(tx, "SELECT pg_advisory_xact_lock($1::bigint)", [
        postgleam.int(7_413_706_844),
      ]),
    )
    use upload <- result.try(
      postgleam.query_one(
        tx,
        "SELECT size, expires FROM notify_attachment_uploads WHERE id = $1 FOR UPDATE",
        [postgleam.text(id)],
        {
          use size <- decode.element(0, decode.int)
          use expires <- decode.element(1, decode.int)
          decode.success(#(size, expires))
        },
      ),
    )
    case upload.0 == expected_size {
      False -> Error(postgleam.query_error("attachment upload size mismatch"))
      True -> {
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
            let expires = max(row.1, upload.1)
            use _ <- result.try(
              postgleam.query(
                tx,
                "UPDATE notify_attachments SET expires = $1 WHERE key = $2",
                [postgleam.int(expires), postgleam.text(key)],
              ),
            )
            use _ <- result.try(delete_upload_query(tx, id))
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
            case total + upload.0 > state.max_total {
              True -> Error(postgleam.query_error("attachment quota exceeded"))
              False -> {
                use _ <- result.try(
                  postgleam.query(
                    tx,
                    "INSERT INTO notify_attachments(key, data, size, expires) VALUES ($1, $2, $3, $4)",
                    [
                      postgleam.text(key),
                      postgleam.bytea(<<>>),
                      postgleam.int(upload.0),
                      postgleam.int(upload.1),
                    ],
                  ),
                )
                use _ <- result.try(
                  postgleam.query(
                    tx,
                    "INSERT INTO notify_attachment_chunks(key, byte_offset, data) SELECT $1, byte_offset, data FROM notify_attachment_upload_chunks WHERE upload_id = $2 ORDER BY byte_offset",
                    [postgleam.text(key), postgleam.text(id)],
                  ),
                )
                use _ <- result.try(delete_upload_query(tx, id))
                Ok(attachment_store.Stored(
                  key:,
                  size: upload.0,
                  expires: upload.1,
                ))
              }
            }
          }
          _ -> Error(postgleam.query_error("duplicate attachment key"))
        }
      }
    }
  })
  |> result.map_error(fn(error) {
    case error {
      pg_error.ConnectionError("attachment quota exceeded") ->
        attachment_store.QuotaExceeded(state.max_total)
      pg_error.ConnectionError("attachment upload not found") ->
        attachment_store.NotFound
      other -> map_error(other)
    }
  })
}

fn abort(
  state: State,
  handle: attachment_store.UploadHandle,
) -> #(State, Result(Nil, attachment_store.Error)) {
  let attachment_store.UploadHandle(id) = handle
  #(remove_upload(state, id), abort_upload(state.connection, id))
}

fn abort_upload(
  connection: postgleam.Connection,
  id: String,
) -> Result(Nil, attachment_store.Error) {
  delete_upload_query(connection, id) |> result.map_error(map_error)
}

fn delete_upload_query(
  connection: postgleam.Connection,
  id: String,
) -> Result(Nil, pg_error.Error) {
  postgleam.query(
    connection,
    "DELETE FROM notify_attachment_uploads WHERE id = $1",
    [postgleam.text(id)],
  )
  |> result.map(fn(_) { Nil })
}

fn find_upload(uploads: List(Pending), id: String) -> Option(Pending) {
  uploads
  |> list.find(fn(upload) { upload.id == id })
  |> option.from_result
}

fn replace_upload(uploads: List(Pending), updated: Pending) -> List(Pending) {
  list.map(uploads, fn(upload) {
    case upload.id == updated.id {
      True -> updated
      False -> upload
    }
  })
}

fn remove_upload(state: State, id: String) -> State {
  State(
    ..state,
    uploads: list.filter(state.uploads, fn(upload) { upload.id != id }),
  )
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
  use metadata <- result.try(head(connection, key))
  let total = metadata.size
  case total, range {
    0, None ->
      Ok(attachment_store.Download(data: <<>>, total_size: 0, start: 0, end: -1))
    0, Some(_) -> Error(attachment_store.InvalidRange)
    _, _ -> {
      let #(start, end) = case range {
        None -> #(0, total - 1)
        Some(attachment_store.ByteRange(start, end)) -> #(start, end)
      }
      case start < 0 || end < start || end >= total {
        True -> Error(attachment_store.InvalidRange)
        False -> {
          use chunks <- result.try(read_chunks(connection, key, range))
          case chunks {
            [] -> {
              use data <- result.try(legacy_data(connection, key))
              case bit_array.byte_size(data) == total {
                True -> memory.download(data, range)
                False ->
                  Error(attachment_store.Unavailable(
                    "PostgreSQL attachment chunks are incomplete",
                  ))
              }
            }
            [#(first_offset, _), ..] -> {
              let joined =
                chunks
                |> list.map(fn(chunk) { chunk.1 })
                |> bit_array.concat
              use data <- result.try(
                bit_array.slice(
                  joined,
                  at: start - first_offset,
                  take: end - start + 1,
                )
                |> result.map_error(fn(_) {
                  attachment_store.Unavailable(
                    "PostgreSQL attachment chunks are incomplete",
                  )
                }),
              )
              Ok(attachment_store.Download(
                data:,
                total_size: total,
                start:,
                end:,
              ))
            }
          }
        }
      }
    }
  }
}

fn read_chunks(
  connection: postgleam.Connection,
  key: String,
  range: Option(attachment_store.ByteRange),
) -> Result(List(#(Int, BitArray)), attachment_store.Error) {
  let #(query, parameters) = case range {
    None -> #(
      "SELECT byte_offset, data FROM notify_attachment_chunks WHERE key = $1 ORDER BY byte_offset",
      [postgleam.text(key)],
    )
    Some(attachment_store.ByteRange(start, end)) -> #(
      "SELECT byte_offset, data FROM notify_attachment_chunks WHERE key = $1 AND byte_offset <= $2 AND byte_offset + octet_length(data) > $3 ORDER BY byte_offset",
      [postgleam.text(key), postgleam.int(end), postgleam.int(start)],
    )
  }
  postgleam.query_with(connection, query, parameters, {
    use byte_offset <- decode.element(0, decode.int)
    use data <- decode.element(1, decode.bytea)
    decode.success(#(byte_offset, data))
  })
  |> result.map(fn(response) { response.rows })
  |> result.map_error(map_error)
}

fn read_range(
  connection: postgleam.Connection,
  key: String,
  start: Int,
  length: Int,
) -> Result(BitArray, attachment_store.Error) {
  let end = start + length - 1
  use chunks <- result.try(read_chunk_range(connection, key, start, end))
  let data = chunks |> list.map(fn(chunk) { chunk.1 }) |> bit_array.concat
  case bit_array.byte_size(data) == length {
    True -> Ok(data)
    False -> read_legacy_range(connection, key, start, length)
  }
}

fn read_chunk_range(
  connection: postgleam.Connection,
  key: String,
  start: Int,
  end: Int,
) -> Result(List(#(Int, BitArray)), attachment_store.Error) {
  postgleam.query_with(
    connection,
    "SELECT GREATEST(byte_offset, $2), substring(data FROM (GREATEST(byte_offset, $2) - byte_offset + 1)::integer FOR (LEAST(byte_offset + octet_length(data) - 1, $3) - GREATEST(byte_offset, $2) + 1)::integer) FROM notify_attachment_chunks WHERE key = $1 AND byte_offset <= $3 AND byte_offset + octet_length(data) > $2 ORDER BY byte_offset",
    [postgleam.text(key), postgleam.int(start), postgleam.int(end)],
    {
      use byte_offset <- decode.element(0, decode.int)
      use data <- decode.element(1, decode.bytea)
      decode.success(#(byte_offset, data))
    },
  )
  |> result.map(fn(response) { response.rows })
  |> result.map_error(map_error)
}

fn read_legacy_range(
  connection: postgleam.Connection,
  key: String,
  start: Int,
  length: Int,
) -> Result(BitArray, attachment_store.Error) {
  use response <- result.try(
    postgleam.query_with(
      connection,
      "SELECT substring(data FROM ($2 + 1)::integer FOR $3::integer) FROM notify_attachments WHERE key = $1",
      [postgleam.text(key), postgleam.int(start), postgleam.int(length)],
      {
        use data <- decode.element(0, decode.bytea)
        decode.success(data)
      },
    )
    |> result.map_error(map_error),
  )
  use data <- result.try(response.rows |> one_or_not_found)
  case bit_array.byte_size(data) == length {
    True -> Ok(data)
    False ->
      Error(attachment_store.Unavailable(
        "PostgreSQL attachment chunks are incomplete",
      ))
  }
}

fn legacy_data(
  connection: postgleam.Connection,
  key: String,
) -> Result(BitArray, attachment_store.Error) {
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
  response.rows |> one_or_not_found
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

fn page_objects(
  connection: postgleam.Connection,
  after: Option(String),
  limit: Int,
) -> Result(
  attachment_store.Page(attachment_store.Stored),
  attachment_store.Error,
) {
  case attachment_store.valid_page(after, limit) {
    False -> Error(attachment_store.InvalidPage)
    True -> {
      let rows = case after {
        None ->
          postgleam.query_with(
            connection,
            "SELECT key, size, expires FROM notify_attachments ORDER BY key LIMIT $1",
            [postgleam.int(limit + 1)],
            stored_decoder(),
          )
        Some(after) ->
          postgleam.query_with(
            connection,
            "SELECT key, size, expires FROM notify_attachments WHERE key > $1 ORDER BY key LIMIT $2",
            [postgleam.text(after), postgleam.int(limit + 1)],
            stored_decoder(),
          )
      }
      rows
      |> result.map(fn(response) {
        attachment_store.Page(
          items: list.take(response.rows, limit),
          has_more: list.length(response.rows) > limit,
        )
      })
      |> result.map_error(map_error)
    }
  }
}

fn stored_decoder() -> decode.RowDecoder(attachment_store.Stored) {
  use key <- decode.element(0, decode.text)
  use size <- decode.element(1, decode.int)
  use expires <- decode.element(2, decode.int)
  decode.success(attachment_store.Stored(key:, size:, expires:))
}

fn cleanup(
  connection: postgleam.Connection,
  now: Int,
) -> Result(Int, attachment_store.Error) {
  use _ <- result.try(
    postgleam.query(
      connection,
      "DELETE FROM notify_attachment_uploads WHERE created_at <= to_timestamp($1 - 3600)",
      [postgleam.int(now)],
    )
    |> result.map_error(map_error),
  )
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

fn min(a: Int, b: Int) -> Int {
  case a < b {
    True -> a
    False -> b
  }
}

@external(erlang, "notify_ffi", "unix_seconds")
fn unix_seconds() -> Int
