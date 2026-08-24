import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option}
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
  State(config: Config, max_file: Int, max_total: Int)
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
  config: Config,
  max_file_bytes max_file: Int,
  max_total_bytes max_total: Int,
) -> Result(Store, attachment_store.Error) {
  use started <- result.try(
    actor.new(State(config:, max_file:, max_total:))
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(fn(_) {
      attachment_store.Unavailable("S3 attachment actor failed to start")
    }),
  )
  let subject = started.data
  let store =
    attachment_store.Store(
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
    Put(upload, reply) -> process.send(reply, put(state, upload))
    Head(key, reply) -> process.send(reply, head(state.config, key))
    Get(key, range, reply) -> process.send(reply, get(state.config, key, range))
    List(reply) -> process.send(reply, list_objects(state.config))
    Delete(key, reply) -> process.send(reply, delete(state.config, key))
    Cleanup(now, reply) -> process.send(reply, cleanup(state.config, now))
    Health(reply) -> process.send(reply, health(state.config))
  }
  actor.continue(state)
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
