import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import notify/attachment_store.{type Store}

type Object {
  Object(key: String, data: BitArray, expires: Int)
}

type State {
  State(objects: List(Object), total: Int, max_file: Int, max_total: Int)
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

pub fn start(
  max_file_bytes max_file: Int,
  max_total_bytes max_total: Int,
) -> Result(Store, actor.StartError) {
  use started <- result.try(
    actor.new(State(objects: [], total: 0, max_file:, max_total:))
    |> actor.on_message(handle)
    |> actor.start,
  )
  let subject = started.data
  Ok(
    attachment_store.Store(
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

fn put(
  state: State,
  upload: attachment_store.Upload,
) -> #(State, Result(attachment_store.Stored, attachment_store.Error)) {
  let size = bit_array.byte_size(upload.data)
  let key = attachment_store.content_key(upload.data)
  case size > state.max_file, find(state.objects, key) {
    True, _ -> #(state, Error(attachment_store.TooLarge(state.max_file, size)))
    False, Some(existing) -> {
      let expires = max(existing.expires, upload.expires)
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
    False, None if state.total + size > state.max_total -> #(
      state,
      Error(attachment_store.QuotaExceeded(state.max_total)),
    )
    False, None -> #(
      State(
        ..state,
        objects: [
          Object(key:, data: upload.data, expires: upload.expires),
          ..state.objects
        ],
        total: state.total + size,
      ),
      Ok(attachment_store.Stored(key:, size:, expires: upload.expires)),
    )
  }
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
  let total =
    list.fold(retained, 0, fn(sum, object) {
      sum + bit_array.byte_size(object.data)
    })
  #(
    State(..state, objects: retained, total:),
    list.length(state.objects) - list.length(retained),
  )
}

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
