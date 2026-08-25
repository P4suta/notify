import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import gleam/result
import gleam/string
import notify/attachment_store.{type Store}

type Object {
  Object(key: String, data: BitArray, expires: Int)
}

type Pending {
  Pending(
    id: String,
    data: BitArray,
    expires: Int,
    started_at: Int,
    size: Int,
    hasher: attachment_store.Hasher,
  )
}

type State {
  State(
    objects: List(Object),
    uploads: List(Pending),
    total: Int,
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
  max_file_bytes max_file: Int,
  max_total_bytes max_total: Int,
) -> Result(Store, actor.StartError) {
  use started <- result.try(
    actor.new(State(objects: [], uploads: [], total: 0, max_file:, max_total:))
    |> actor.on_message(handle)
    |> actor.start,
  )
  let subject = started.data
  Ok(
    attachment_store.Store(
      begin: fn(upload) {
        process.call(subject, 5000, fn(reply) { Begin(upload, reply) })
      },
      write: fn(handle, chunk) {
        process.call(subject, 5000, fn(reply) { Write(handle, chunk, reply) })
      },
      finish: fn(handle) {
        process.call(subject, 5000, fn(reply) { Finish(handle, reply) })
      },
      abort: fn(handle) {
        process.call(subject, 5000, fn(reply) { Abort(handle, reply) })
      },
      put: fn(upload) {
        process.call(subject, 5000, fn(reply) { Put(upload, reply) })
      },
      head: fn(key) {
        process.call(subject, 5000, fn(reply) { Head(key, reply) })
      },
      get: fn(key, range) {
        process.call(subject, 5000, fn(reply) { Get(key, range, reply) })
      },
      list: fn() { process.call(subject, 5000, List) },
      page: fn(after, limit) {
        process.call(subject, 5000, fn(reply) { Page(after, limit, reply) })
      },
      delete: fn(key) {
        process.call(subject, 5000, fn(reply) { Delete(key, reply) })
      },
      cleanup: fn(now) {
        process.call(subject, 5000, fn(reply) { Cleanup(now, reply) })
      },
      health: fn() { process.call(subject, 5000, Health) },
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
      process.send(reply, Ok(Nil))
      actor.continue(remove_upload(state, handle))
    }
    Put(upload, reply) -> {
      let #(next, response) = put(state, upload)
      process.send(reply, response)
      actor.continue(next)
    }
    Head(key, reply) -> {
      process.send(reply, head(state, key))
      actor.continue(state)
    }
    Get(key, range, reply) -> {
      process.send(reply, get(state, key, range))
      actor.continue(state)
    }
    List(reply) -> {
      process.send(reply, Ok(list_objects(state)))
      actor.continue(state)
    }
    Page(after, limit, reply) -> {
      process.send(reply, page_objects(state, after, limit))
      actor.continue(state)
    }
    Delete(key, reply) -> {
      let #(next, response) = delete(state, key)
      process.send(reply, response)
      actor.continue(next)
    }
    Cleanup(now, reply) -> {
      let #(next, count) = cleanup(state, now)
      process.send(reply, Ok(count))
      actor.continue(next)
    }
    Health(reply) -> {
      process.send(reply, Ok(Nil))
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
        None -> #(
          State(..state, uploads: [
            Pending(
              id:,
              data: <<>>,
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
        True -> #(
          remove_upload(state, handle),
          Error(attachment_store.TooLarge(state.max_file, actual)),
        )
        False -> {
          let updated =
            Pending(
              ..upload,
              data: bit_array.append(upload.data, chunk),
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

fn finish(
  state: State,
  handle: attachment_store.UploadHandle,
) -> #(State, Result(attachment_store.Stored, attachment_store.Error)) {
  let attachment_store.UploadHandle(id) = handle
  case find_upload(state.uploads, id) {
    None -> #(state, Error(attachment_store.NotFound))
    Some(upload) -> {
      let without_upload = remove_upload(state, handle)
      promote(
        without_upload,
        attachment_store.finish_hash(upload.hasher),
        upload.data,
        upload.expires,
      )
    }
  }
}

fn put(
  state: State,
  upload: attachment_store.Upload,
) -> #(State, Result(attachment_store.Stored, attachment_store.Error)) {
  let size = bit_array.byte_size(upload.data)
  let key = attachment_store.content_key(upload.data)
  case size > state.max_file {
    True -> #(state, Error(attachment_store.TooLarge(state.max_file, size)))
    False -> promote(state, key, upload.data, upload.expires)
  }
}

fn promote(
  state: State,
  key: String,
  data: BitArray,
  expires: Int,
) -> #(State, Result(attachment_store.Stored, attachment_store.Error)) {
  let size = bit_array.byte_size(data)
  case find(state.objects, key) {
    Some(existing) -> {
      let expires = max(existing.expires, expires)
      let updated =
        list.map(state.objects, fn(object) {
          case object.key == key {
            True -> Object(..object, expires:)
            False -> object
          }
        })
      #(
        State(..state, objects: updated),
        Ok(attachment_store.Stored(key:, size:, expires:)),
      )
    }
    None if state.total + size > state.max_total -> #(
      state,
      Error(attachment_store.QuotaExceeded(state.max_total)),
    )
    None -> #(
      State(
        ..state,
        objects: [Object(key:, data:, expires:), ..state.objects],
        total: state.total + size,
      ),
      Ok(attachment_store.Stored(key:, size:, expires:)),
    )
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

fn remove_upload(state: State, handle: attachment_store.UploadHandle) -> State {
  let attachment_store.UploadHandle(id) = handle
  State(
    ..state,
    uploads: list.filter(state.uploads, fn(upload) { upload.id != id }),
  )
}

fn head(
  state: State,
  key: String,
) -> Result(attachment_store.Stored, attachment_store.Error) {
  case find(state.objects, key) {
    None -> Error(attachment_store.NotFound)
    Some(object) ->
      Ok(attachment_store.Stored(
        key:,
        size: bit_array.byte_size(object.data),
        expires: object.expires,
      ))
  }
}

fn get(
  state: State,
  key: String,
  range: Option(attachment_store.ByteRange),
) -> Result(attachment_store.Download, attachment_store.Error) {
  case find(state.objects, key) {
    None -> Error(attachment_store.NotFound)
    Some(object) -> download(object.data, range)
  }
}

pub fn download(
  data: BitArray,
  range: Option(attachment_store.ByteRange),
) -> Result(attachment_store.Download, attachment_store.Error) {
  let total = bit_array.byte_size(data)
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
        False ->
          data
          |> bit_array.slice(at: start, take: end - start + 1)
          |> result.map(fn(partial) {
            attachment_store.Download(
              data: partial,
              total_size: total,
              start:,
              end:,
            )
          })
          |> result.map_error(fn(_) { attachment_store.InvalidRange })
      }
    }
  }
}

fn delete(
  state: State,
  key: String,
) -> #(State, Result(Nil, attachment_store.Error)) {
  case find(state.objects, key) {
    None -> #(state, Ok(Nil))
    Some(object) -> #(
      State(
        ..state,
        objects: list.filter(state.objects, fn(item) { item.key != key }),
        total: state.total - bit_array.byte_size(object.data),
      ),
      Ok(Nil),
    )
  }
}

fn cleanup(state: State, now: Int) -> #(State, Int) {
  let retained = list.filter(state.objects, fn(object) { object.expires > now })
  let uploads =
    list.filter(state.uploads, fn(upload) { upload.started_at > now - 3600 })
  let total =
    list.fold(retained, 0, fn(sum, object) {
      sum + bit_array.byte_size(object.data)
    })
  #(
    State(..state, objects: retained, uploads:, total:),
    list.length(state.objects) - list.length(retained),
  )
}

@external(erlang, "notify_ffi", "unix_seconds")
fn unix_seconds() -> Int

fn list_objects(state: State) -> List(attachment_store.Stored) {
  state.objects
  |> list.map(fn(object) {
    attachment_store.Stored(
      key: object.key,
      size: bit_array.byte_size(object.data),
      expires: object.expires,
    )
  })
  |> list.sort(fn(first, second) { string.compare(first.key, second.key) })
}

fn page_objects(
  state: State,
  after: Option(String),
  limit: Int,
) -> Result(
  attachment_store.Page(attachment_store.Stored),
  attachment_store.Error,
) {
  case attachment_store.valid_page(after, limit) {
    False -> Error(attachment_store.InvalidPage)
    True -> {
      let selected = case after {
        None -> list_objects(state)
        Some(after) ->
          list_objects(state)
          |> list.filter(fn(item) {
            string.compare(item.key, after) == order.Gt
          })
      }
      Ok(attachment_store.Page(
        items: list.take(selected, limit),
        has_more: list.length(selected) > limit,
      ))
    }
  }
}

fn find(objects: List(Object), key: String) -> Option(Object) {
  objects
  |> list.find(fn(object) { object.key == key })
  |> option.from_result
}

fn max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}
