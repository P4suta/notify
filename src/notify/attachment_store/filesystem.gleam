import gleam/bit_array
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string
import notify/attachment_store.{type Store}
import notify/attachment_store/memory

pub fn start(
  directory: String,
  max_file_bytes max_file: Int,
  max_total_bytes max_total: Int,
) -> Result(Store, attachment_store.Error) {
  use _ <- result.try(
    ensure_directory(directory) |> result.map_error(map_external_error),
  )
  Ok(
    attachment_store.Store(
      put: fn(upload) { put(directory, max_file, max_total, upload) },
      head: fn(key) { head(directory, key) },
      get: fn(key, range) { get(directory, key, range) },
      list: fn() {
        attachment_list(directory)
        |> result.map(fn(items) {
          list.map(items, fn(item) {
            attachment_store.Stored(key: item.0, size: item.1, expires: item.2)
          })
        })
        |> result.map_error(map_external_error)
      },
      delete: fn(key) { delete(directory, key) },
      cleanup: fn(now) {
        cleanup_expired(directory, now) |> result.map_error(map_external_error)
      },
      health: fn() {
        attachment_health(directory) |> result.map_error(map_external_error)
      },
    ),
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
      Ok(attachment_store.Stored(key:, size:, expires: upload.expires))
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
  use data <- result.try(
    attachment_read(directory, key) |> result.map_error(map_external_error),
  )
  memory.download(data, range)
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

fn map_external_error(error: String) -> attachment_store.Error {
  case error {
    "quota" -> attachment_store.QuotaExceeded(0)
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

@external(erlang, "notify_ffi", "attachment_head")
fn attachment_head(
  directory: String,
  key: String,
) -> Result(#(Int, Int), String)

@external(erlang, "notify_ffi", "attachment_read")
fn attachment_read(directory: String, key: String) -> Result(BitArray, String)

@external(erlang, "notify_ffi", "attachment_delete")
fn attachment_delete(directory: String, key: String) -> Result(Nil, String)

@external(erlang, "notify_ffi", "attachment_list")
fn attachment_list(
  directory: String,
) -> Result(List(#(String, Int, Int)), String)

@external(erlang, "notify_ffi", "attachment_cleanup_expired")
fn cleanup_expired(directory: String, now: Int) -> Result(Int, String)

@external(erlang, "notify_ffi", "attachment_health")
fn attachment_health(directory: String) -> Result(Nil, String)

@external(erlang, "notify_ffi", "make_temporary_directory")
fn make_temporary_directory() -> Result(String, String)
