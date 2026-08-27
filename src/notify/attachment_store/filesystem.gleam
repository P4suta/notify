import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import notify/attachment_store.{type Store}

type Pending {
  Pending(
    id: String,
    expires: Int,
    started_at: Int,
    size: Int,
    hasher: attachment_store.Hasher,
  )
}

type State {
  State(
    directory: String,
    uploads: List(Pending),
    max_file: Int,
    max_total: Int,
  )
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
  Head(String, Subject(Result(attachment_store.Stored, attachment_store.Error)))
  Get(
    String,
    Option(attachment_store.ByteRange),
    Subject(Result(attachment_store.Download, attachment_store.Error)),
  )
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
  Delete(String, Subject(Result(Nil, attachment_store.Error)))
  Cleanup(Int, Subject(Result(Int, attachment_store.Error)))
  Health(Subject(Result(Nil, attachment_store.Error)))
}

pub fn start(
  directory: String,
  max_file_bytes max_file: Int,
  max_total_bytes max_total: Int,
) -> Result(Store, attachment_store.Error) {
  use _ <- result.try(
    ensure_directory(directory) |> result.map_error(map_external_error),
  )
  use started <- result.try(
    actor.new(State(directory:, uploads: [], max_file:, max_total:))
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(fn(_) {
      attachment_store.Unavailable(
        "filesystem attachment actor failed to start",
      )
    }),
  )
  let subject = started.data
  Ok(
    attachment_store.Store(
      begin: fn(upload) {
        process.call(subject, 10_000, fn(reply) { Begin(upload, reply) })
      },
      write: fn(handle, chunk) {
        process.call(subject, 30_000, fn(reply) { Write(handle, chunk, reply) })
      },
      finish: fn(handle) {
        process.call(subject, 30_000, fn(reply) { Finish(handle, reply) })
      },
      abort: fn(handle) {
        process.call(subject, 10_000, fn(reply) { Abort(handle, reply) })
      },
      put: fn(upload) {
        process.call(subject, 30_000, fn(reply) { Put(upload, reply) })
      },
      head: fn(key) {
        process.call(subject, 10_000, fn(reply) { Head(key, reply) })
      },
      get: fn(key, range) {
        process.call(subject, 30_000, fn(reply) { Get(key, range, reply) })
      },
      open: fn(key, range) {
        use metadata <- result.try(
          process.call(subject, 10_000, fn(reply) { Head(key, reply) }),
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
              attachment_read_range(directory, key, offset, offset + length - 1)
              |> result.map_error(map_external_error)
            },
            fn() { Nil },
          ),
        )
      },
      list: fn() { process.call(subject, 30_000, List) },
      page: fn(after, limit) {
        process.call(subject, 30_000, fn(reply) { Page(after, limit, reply) })
      },
      delete: fn(key) {
        process.call(subject, 10_000, fn(reply) { Delete(key, reply) })
      },
      cleanup: fn(now) {
        process.call(subject, 30_000, fn(reply) { Cleanup(now, reply) })
      },
      health: fn() { process.call(subject, 10_000, Health) },
    ),
  )
}

fn handle(state: State, command: Command) -> actor.Next(State, Command) {
  case command {
    Begin(upload, reply) -> {
      let #(next, response) = begin(state, upload, 8)
      process.send(reply, response)
      actor.continue(next)
    }
    Write(handle, chunk, reply) -> {
      let #(next, response) = write(state, handle, chunk)
      process.send(reply, response)
      actor.continue(next)
    }
    Finish(handle, reply) -> {
      let #(next, response) = finish(state, handle)
      process.send(reply, response)
      actor.continue(next)
    }
    Abort(handle, reply) -> {
      let #(next, response) = abort(state, handle)
      process.send(reply, response)
      actor.continue(next)
    }
    Put(upload, reply) -> {
      process.send(
        reply,
        put(state.directory, state.max_file, state.max_total, upload),
      )
      actor.continue(state)
    }
    Head(key, reply) -> {
      process.send(reply, head(state.directory, key))
      actor.continue(state)
    }
    Get(key, range, reply) -> {
      process.send(reply, get(state.directory, key, range))
      actor.continue(state)
    }
    List(reply) -> {
      let response =
        attachment_list(state.directory)
        |> result.map(fn(items) {
          list.map(items, fn(item) {
            attachment_store.Stored(key: item.0, size: item.1, expires: item.2)
          })
        })
        |> result.map_error(map_external_error)
      process.send(reply, response)
      actor.continue(state)
    }
    Page(after, limit, reply) -> {
      process.send(reply, page(state.directory, after, limit))
      actor.continue(state)
    }
    Delete(key, reply) -> {
      process.send(reply, delete(state.directory, key))
      actor.continue(state)
    }
    Cleanup(now, reply) -> {
      let next =
        State(
          ..state,
          uploads: list.filter(state.uploads, fn(upload) {
            upload.started_at > now - 3600
          }),
        )
      process.send(
        reply,
        cleanup_expired(state.directory, now)
          |> result.map_error(map_external_error),
      )
      actor.continue(next)
    }
    Health(reply) -> {
      process.send(
        reply,
        attachment_health(state.directory)
          |> result.map_error(map_external_error),
      )
      actor.continue(state)
    }
  }
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
      case attachment_upload_begin(state.directory, id) {
        Error("exists") -> begin(state, upload, attempts - 1)
        Error(detail) -> #(state, Error(map_external_error(detail)))
        Ok(_) -> #(
          State(..state, uploads: [
            Pending(
              id:,
              expires: upload.expires,
              started_at: unix_seconds(),
              size: 0,
              hasher: attachment_store.new_hasher(),
            ),
            ..state.uploads
          ]),
          Ok(attachment_store.UploadHandle(id:)),
        )
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
          let _ = attachment_upload_abort(state.directory, id)
          #(
            remove_upload(state, id),
            Error(attachment_store.TooLarge(state.max_file, actual)),
          )
        }
        False ->
          case attachment_upload_write(state.directory, id, chunk) {
            Error(detail) -> {
              let _ = attachment_upload_abort(state.directory, id)
              #(remove_upload(state, id), Error(map_external_error(detail)))
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

fn finish(
  state: State,
  handle: attachment_store.UploadHandle,
) -> #(State, Result(attachment_store.Stored, attachment_store.Error)) {
  let attachment_store.UploadHandle(id) = handle
  case find_upload(state.uploads, id) {
    None -> #(state, Error(attachment_store.NotFound))
    Some(upload) -> {
      let key = attachment_store.finish_hash(upload.hasher)
      let next = remove_upload(state, id)
      case
        attachment_upload_finish(
          state.directory,
          id,
          key,
          upload.expires,
          state.max_total,
          upload.size,
        )
      {
        Ok(metadata) -> #(
          next,
          Ok(attachment_store.Stored(
            key:,
            size: metadata.0,
            expires: metadata.1,
          )),
        )
        Error("quota") -> {
          let _ = attachment_upload_abort(state.directory, id)
          #(next, Error(attachment_store.QuotaExceeded(state.max_total)))
        }
        Error(detail) -> {
          let _ = attachment_upload_abort(state.directory, id)
          #(next, Error(map_external_error(detail)))
        }
      }
    }
  }
}

fn abort(
  state: State,
  handle: attachment_store.UploadHandle,
) -> #(State, Result(Nil, attachment_store.Error)) {
  let attachment_store.UploadHandle(id) = handle
  case attachment_upload_abort(state.directory, id) {
    Ok(_) | Error("not_found") -> #(remove_upload(state, id), Ok(Nil))
    Error(detail) -> #(state, Error(map_external_error(detail)))
  }
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
  directory: String,
  max_file: Int,
  max_total: Int,
  upload: attachment_store.Upload,
) -> Result(attachment_store.Stored, attachment_store.Error) {
  let size = bit_array.byte_size(upload.data)
  case size > max_file {
    True -> Error(attachment_store.TooLarge(max_file, size))
    False -> {
      let key = attachment_store.content_key(upload.data)
      use _ <- result.try(
        attachment_put(directory, key, upload.data, upload.expires, max_total)
        |> result.map_error(fn(error) {
          case error {
            "quota" -> attachment_store.QuotaExceeded(max_total)
            other -> map_external_error(other)
          }
        }),
      )
      head(directory, key)
    }
  }
}

fn head(
  directory: String,
  key: String,
) -> Result(attachment_store.Stored, attachment_store.Error) {
  use _ <- result.try(validate_key(key))
  attachment_head(directory, key)
  |> result.map(fn(metadata) {
    attachment_store.Stored(key:, size: metadata.0, expires: metadata.1)
  })
  |> result.map_error(map_external_error)
}

fn get(
  directory: String,
  key: String,
  range: Option(attachment_store.ByteRange),
) -> Result(attachment_store.Download, attachment_store.Error) {
  use _ <- result.try(validate_key(key))
  use metadata <- result.try(head(directory, key))
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
          use data <- result.try(
            attachment_read_range(directory, key, start, end)
            |> result.map_error(map_external_error),
          )
          Ok(attachment_store.Download(data:, total_size: total, start:, end:))
        }
      }
    }
  }
}

fn delete(
  directory: String,
  key: String,
) -> Result(Nil, attachment_store.Error) {
  use _ <- result.try(validate_key(key))
  attachment_delete(directory, key) |> result.map_error(map_external_error)
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

/// Returns the immutable blob path for an already content-addressed object.
/// HTTP transports use this only after the normal store metadata and topic
/// authorization checks have succeeded.
pub fn blob_path(
  directory: String,
  key: String,
) -> Result(String, attachment_store.Error) {
  use _ <- result.try(validate_key(key))
  Ok(attachment_blob_path(directory, key))
}

fn page(
  directory: String,
  after: Option(String),
  limit: Int,
) -> Result(
  attachment_store.Page(attachment_store.Stored),
  attachment_store.Error,
) {
  case attachment_store.valid_page(after, limit) {
    False -> Error(attachment_store.InvalidPage)
    True ->
      attachment_page(directory, after, limit + 1)
      |> result.map(fn(items) {
        let stored =
          list.map(items, fn(item) {
            attachment_store.Stored(key: item.0, size: item.1, expires: item.2)
          })
        attachment_store.Page(
          items: list.take(stored, limit),
          has_more: list.length(stored) > limit,
        )
      })
      |> result.map_error(map_external_error)
  }
}

fn map_external_error(error: String) -> attachment_store.Error {
  case error {
    "quota" -> attachment_store.QuotaExceeded(0)
    "invalid_range" -> attachment_store.InvalidRange
    "not_found" -> attachment_store.NotFound
    detail -> attachment_store.Unavailable(detail)
  }
}

pub fn temporary_directory() -> Result(String, attachment_store.Error) {
  make_temporary_directory() |> result.map_error(map_external_error)
}

@external(erlang, "notify_ffi", "attachment_ensure_directory")
fn ensure_directory(path: String) -> Result(Nil, String)

@external(erlang, "notify_ffi", "attachment_put")
fn attachment_put(
  directory: String,
  key: String,
  data: BitArray,
  expires: Int,
  max_total: Int,
) -> Result(Nil, String)

@external(erlang, "notify_ffi", "attachment_upload_begin")
fn attachment_upload_begin(directory: String, id: String) -> Result(Nil, String)

@external(erlang, "notify_ffi", "attachment_upload_write")
fn attachment_upload_write(
  directory: String,
  id: String,
  chunk: BitArray,
) -> Result(Nil, String)

@external(erlang, "notify_ffi", "attachment_upload_finish")
fn attachment_upload_finish(
  directory: String,
  id: String,
  key: String,
  expires: Int,
  max_total: Int,
  expected_size: Int,
) -> Result(#(Int, Int), String)

@external(erlang, "notify_ffi", "attachment_upload_abort")
fn attachment_upload_abort(directory: String, id: String) -> Result(Nil, String)

@external(erlang, "notify_ffi", "attachment_head")
fn attachment_head(
  directory: String,
  key: String,
) -> Result(#(Int, Int), String)

@external(erlang, "notify_ffi", "attachment_read_range")
fn attachment_read_range(
  directory: String,
  key: String,
  start: Int,
  end: Int,
) -> Result(BitArray, String)

@external(erlang, "notify_ffi", "attachment_delete")
fn attachment_delete(directory: String, key: String) -> Result(Nil, String)

@external(erlang, "notify_ffi", "attachment_list")
fn attachment_list(
  directory: String,
) -> Result(List(#(String, Int, Int)), String)

@external(erlang, "notify_ffi", "attachment_page")
fn attachment_page(
  directory: String,
  after: Option(String),
  limit: Int,
) -> Result(List(#(String, Int, Int)), String)

@external(erlang, "notify_ffi", "attachment_cleanup_expired")
fn cleanup_expired(directory: String, now: Int) -> Result(Int, String)

@external(erlang, "notify_ffi", "attachment_health")
fn attachment_health(directory: String) -> Result(Nil, String)

@external(erlang, "notify_ffi", "attachment_blob_path")
fn attachment_blob_path(directory: String, key: String) -> String

@external(erlang, "notify_ffi", "make_temporary_directory")
fn make_temporary_directory() -> Result(String, String)

@external(erlang, "notify_ffi", "unix_seconds")
fn unix_seconds() -> Int
