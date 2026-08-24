import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import notify/attachment_store.{type Store}

pub type Config {
  Config(
    endpoint: String,
    bucket: String,
    region: String,
    access_key: String,
    secret_key: String,
    path_style: Bool,
  )
}

type State {
  State(config: Config, uploads: List(Pending), max_file: Int, max_total: Int)
}

type Pending {
  Pending(
    id: String,
    staging_key: String,
    multipart_id: String,
    buffered: BitArray,
    expires: Int,
    started_at: Int,
    size: Int,
    hasher: attachment_store.Hasher,
    next_part: Int,
    parts: List(#(Int, String)),
  )
}

const multipart_chunk_bytes = 5_242_880

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
  Delete(String, Subject(Result(Nil, attachment_store.Error)))
  Cleanup(Int, Subject(Result(Int, attachment_store.Error)))
  Health(Subject(Result(Nil, attachment_store.Error)))
}

pub fn start(
  config: Config,
  max_file_bytes max_file: Int,
  max_total_bytes max_total: Int,
) -> Result(Store, attachment_store.Error) {
  use started <- result.try(
    actor.new(State(config:, uploads: [], max_file:, max_total:))
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(fn(_) {
      attachment_store.Unavailable("S3 attachment actor failed to start")
    }),
  )
  let subject = started.data
  let store =
    attachment_store.Store(
      begin: fn(upload) {
        process.call(subject, 30_000, fn(reply) { Begin(upload, reply) })
      },
      write: fn(handle, chunk) {
        process.call(subject, 60_000, fn(reply) { Write(handle, chunk, reply) })
      },
      finish: fn(handle) {
        process.call(subject, 60_000, fn(reply) { Finish(handle, reply) })
      },
      abort: fn(handle) {
        process.call(subject, 30_000, fn(reply) { Abort(handle, reply) })
      },
      put: fn(upload) {
        process.call(subject, 60_000, fn(reply) { Put(upload, reply) })
      },
      head: fn(key) {
        process.call(subject, 30_000, fn(reply) { Head(key, reply) })
      },
      get: fn(key, range) {
        process.call(subject, 60_000, fn(reply) { Get(key, range, reply) })
      },
      list: fn() { process.call(subject, 60_000, List) },
      delete: fn(key) {
        process.call(subject, 30_000, fn(reply) { Delete(key, reply) })
      },
      cleanup: fn(now) {
        process.call(subject, 60_000, fn(reply) { Cleanup(now, reply) })
      },
      health: fn() { process.call(subject, 30_000, Health) },
    )
  use _ <- result.try(store.health())
  Ok(store)
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
      let attachment_store.UploadHandle(id) = handle
      case find_upload(state.uploads, id) {
        None -> {
          process.send(reply, Ok(Nil))
          actor.continue(state)
        }
        Some(upload) -> {
          case abort_multipart(state.config, upload) {
            Ok(_) -> {
              process.send(reply, Ok(Nil))
              actor.continue(remove_upload(state, handle))
            }
            Error(error) -> {
              process.send(reply, Error(error))
              actor.continue(state)
            }
          }
        }
      }
    }
    Put(upload, reply) -> {
      process.send(reply, put(state, upload))
      actor.continue(state)
    }
    Head(key, reply) -> {
      process.send(reply, head(state.config, key))
      actor.continue(state)
    }
    Get(key, range, reply) -> {
      process.send(reply, get(state.config, key, range))
      actor.continue(state)
    }
    List(reply) -> {
      process.send(reply, list_objects(state.config))
      actor.continue(state)
    }
    Delete(key, reply) -> {
      process.send(reply, delete(state.config, key))
      actor.continue(state)
    }
    Cleanup(now, reply) -> {
      case cleanup(state.config, now) {
        Ok(count) -> {
          process.send(reply, Ok(count))
          actor.continue(
            State(
              ..state,
              uploads: list.filter(state.uploads, fn(upload) {
                upload.started_at > now - 3600
              }),
            ),
          )
        }
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
      }
    }
    Health(reply) -> {
      process.send(reply, health(state.config))
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
      case find_upload(state.uploads, id) {
        Some(_) -> begin(state, upload, attempts - 1)
        None -> {
          let staging_key = ".staging/" <> id
          case
            s3_multipart_begin(state.config, staging_key, unix_seconds() + 3600)
          {
            Error(detail) -> #(state, Error(map_error(detail)))
            Ok(multipart_id) -> #(
              State(..state, uploads: [
                Pending(
                  id:,
                  staging_key:,
                  multipart_id:,
                  buffered: <<>>,
                  expires: upload.expires,
                  started_at: unix_seconds(),
                  size: 0,
                  hasher: attachment_store.new_hasher(),
                  next_part: 1,
                  parts: [],
                ),
                ..state.uploads
              ]),
              Ok(attachment_store.UploadHandle(id:)),
            )
          }
        }
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
          let _ = abort_multipart(state.config, upload)
          #(
            remove_upload(state, handle),
            Error(attachment_store.TooLarge(state.max_file, actual)),
          )
        }
        False -> {
          let pending =
            Pending(
              ..upload,
              buffered: bit_array.append(upload.buffered, chunk),
              size: actual,
              hasher: attachment_store.hash_chunk(upload.hasher, chunk),
            )
          case flush_complete_parts(state.config, pending) {
            Error(error) -> {
              let _ = abort_multipart(state.config, pending)
              #(remove_upload(state, handle), Error(error))
            }
            Ok(updated) -> #(
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
      let next = remove_upload(state, handle)
      let key = attachment_store.finish_hash(upload.hasher)
      case finish_multipart(state, upload, key) {
        Error(error) -> #(next, Error(error))
        Ok(stored) -> #(next, Ok(stored))
      }
    }
  }
}

fn flush_complete_parts(
  config: Config,
  upload: Pending,
) -> Result(Pending, attachment_store.Error) {
  case bit_array.byte_size(upload.buffered) >= multipart_chunk_bytes {
    False -> Ok(upload)
    True -> {
      use part <- result.try(
        bit_array.slice(upload.buffered, at: 0, take: multipart_chunk_bytes)
        |> result.map_error(fn(_) {
          attachment_store.Unavailable("invalid S3 multipart chunk")
        }),
      )
      let remaining_size =
        bit_array.byte_size(upload.buffered) - multipart_chunk_bytes
      use remaining <- result.try(case remaining_size {
        0 -> Ok(<<>>)
        _ ->
          bit_array.slice(
            upload.buffered,
            at: multipart_chunk_bytes,
            take: remaining_size,
          )
          |> result.map_error(fn(_) {
            attachment_store.Unavailable("invalid S3 multipart remainder")
          })
      })
      use etag <- result.try(
        s3_multipart_write(
          config,
          upload.staging_key,
          upload.multipart_id,
          upload.next_part,
          part,
        )
        |> result.map_error(map_error),
      )
      flush_complete_parts(
        config,
        Pending(
          ..upload,
          buffered: remaining,
          next_part: upload.next_part + 1,
          parts: list.append(upload.parts, [#(upload.next_part, etag)]),
        ),
      )
    }
  }
}

fn finish_multipart(
  state: State,
  upload: Pending,
  key: String,
) -> Result(attachment_store.Stored, attachment_store.Error) {
  case upload.size {
    0 -> {
      use _ <- result.try(abort_multipart(state.config, upload))
      use _ <- result.try(
        s3_put(state.config, key, <<>>, upload.expires, state.max_total)
        |> result.map_error(fn(detail) {
          map_error_with_quota(detail, state.max_total)
        }),
      )
      head(state.config, key)
    }
    _ -> {
      use completed <- result.try(upload_final_part(state.config, upload))
      case
        s3_multipart_complete(
          state.config,
          completed.staging_key,
          completed.multipart_id,
          completed.parts,
        )
        |> result.map_error(map_error)
      {
        Error(error) -> {
          let _ = abort_multipart(state.config, completed)
          Error(error)
        }
        Ok(_) ->
          case
            s3_promote_staging(
              state.config,
              completed.staging_key,
              key,
              completed.expires,
              state.max_total,
            )
            |> result.map_error(fn(detail) {
              map_error_with_quota(detail, state.max_total)
            })
          {
            Error(error) -> {
              let _ = s3_delete(state.config, completed.staging_key)
              Error(error)
            }
            Ok(_) -> head(state.config, key)
          }
      }
    }
  }
}

fn upload_final_part(
  config: Config,
  upload: Pending,
) -> Result(Pending, attachment_store.Error) {
  case bit_array.byte_size(upload.buffered) {
    0 -> Ok(upload)
    _ -> {
      use etag <- result.try(
        s3_multipart_write(
          config,
          upload.staging_key,
          upload.multipart_id,
          upload.next_part,
          upload.buffered,
        )
        |> result.map_error(map_error),
      )
      Ok(
        Pending(
          ..upload,
          buffered: <<>>,
          next_part: upload.next_part + 1,
          parts: list.append(upload.parts, [#(upload.next_part, etag)]),
        ),
      )
    }
  }
}

fn abort_multipart(
  config: Config,
  upload: Pending,
) -> Result(Nil, attachment_store.Error) {
  use _ <- result.try(
    s3_multipart_abort(config, upload.staging_key, upload.multipart_id)
    |> result.map_error(map_error),
  )
  s3_delete(config, upload.staging_key) |> result.map_error(map_error)
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

fn remove_upload(state: State, handle: attachment_store.UploadHandle) -> State {
  let attachment_store.UploadHandle(id) = handle
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
      use _ <- result.try(
        s3_put(state.config, key, upload.data, upload.expires, state.max_total)
        |> result.map_error(fn(detail) {
          map_error_with_quota(detail, state.max_total)
        }),
      )
      head(state.config, key)
    }
  }
}

fn head(
  config: Config,
  key: String,
) -> Result(attachment_store.Stored, attachment_store.Error) {
  use _ <- result.try(validate_key(key))
  s3_head(config, key)
  |> result.map(fn(metadata) {
    attachment_store.Stored(key:, size: metadata.0, expires: metadata.1)
  })
  |> result.map_error(map_error)
}

fn get(
  config: Config,
  key: String,
  range: Option(attachment_store.ByteRange),
) -> Result(attachment_store.Download, attachment_store.Error) {
  use _ <- result.try(validate_key(key))
  s3_get(config, key, range)
  |> result.map(fn(download) {
    attachment_store.Download(
      data: download.0,
      total_size: download.1,
      start: download.2,
      end: download.3,
    )
  })
  |> result.map_error(map_error)
}

fn delete(config: Config, key: String) -> Result(Nil, attachment_store.Error) {
  use _ <- result.try(validate_key(key))
  s3_delete(config, key) |> result.map_error(map_error)
}

fn list_objects(
  config: Config,
) -> Result(List(attachment_store.Stored), attachment_store.Error) {
  s3_list(config)
  |> result.map(fn(items) {
    list.map(items, fn(item) {
      attachment_store.Stored(key: item.0, size: item.1, expires: item.2)
    })
  })
  |> result.map_error(map_error)
}

fn cleanup(config: Config, now: Int) -> Result(Int, attachment_store.Error) {
  s3_cleanup(config, now) |> result.map_error(map_error)
}

fn health(config: Config) -> Result(Nil, attachment_store.Error) {
  s3_health(config) |> result.map_error(map_error)
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

fn map_error(detail: String) -> attachment_store.Error {
  map_error_with_quota(detail, 0)
}

fn map_error_with_quota(detail: String, quota: Int) -> attachment_store.Error {
  case detail {
    "not_found" -> attachment_store.NotFound
    "invalid_range" -> attachment_store.InvalidRange
    "quota" -> attachment_store.QuotaExceeded(quota)
    other -> attachment_store.Unavailable(other)
  }
}

@external(erlang, "notify_ffi", "unix_seconds")
fn unix_seconds() -> Int

@external(erlang, "notify_ffi", "s3_multipart_begin")
fn s3_multipart_begin(
  config: Config,
  staging_key: String,
  expires: Int,
) -> Result(String, String)

@external(erlang, "notify_ffi", "s3_multipart_write")
fn s3_multipart_write(
  config: Config,
  staging_key: String,
  multipart_id: String,
  part_number: Int,
  data: BitArray,
) -> Result(String, String)

@external(erlang, "notify_ffi", "s3_multipart_complete")
fn s3_multipart_complete(
  config: Config,
  staging_key: String,
  multipart_id: String,
  parts: List(#(Int, String)),
) -> Result(Nil, String)

@external(erlang, "notify_ffi", "s3_multipart_abort")
fn s3_multipart_abort(
  config: Config,
  staging_key: String,
  multipart_id: String,
) -> Result(Nil, String)

@external(erlang, "notify_ffi", "s3_promote_staging")
fn s3_promote_staging(
  config: Config,
  staging_key: String,
  key: String,
  expires: Int,
  max_total: Int,
) -> Result(Nil, String)

@external(erlang, "notify_ffi", "s3_put")
fn s3_put(
  config: Config,
  key: String,
  data: BitArray,
  expires: Int,
  max_total: Int,
) -> Result(Nil, String)

@external(erlang, "notify_ffi", "s3_head")
fn s3_head(config: Config, key: String) -> Result(#(Int, Int), String)

@external(erlang, "notify_ffi", "s3_get")
fn s3_get(
  config: Config,
  key: String,
  range: Option(attachment_store.ByteRange),
) -> Result(#(BitArray, Int, Int, Int), String)

@external(erlang, "notify_ffi", "s3_delete")
fn s3_delete(config: Config, key: String) -> Result(Nil, String)

@external(erlang, "notify_ffi", "s3_list")
fn s3_list(config: Config) -> Result(List(#(String, Int, Int)), String)

@external(erlang, "notify_ffi", "s3_cleanup")
fn s3_cleanup(config: Config, now: Int) -> Result(Int, String)

@external(erlang, "notify_ffi", "s3_health")
fn s3_health(config: Config) -> Result(Nil, String)
