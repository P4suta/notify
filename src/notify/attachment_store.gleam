import gleam/bit_array
import gleam/list
import gleam/option.{type Option}
import gleam/result
import gleam/string

pub type Upload {
  Upload(data: BitArray, expires: Int)
}

pub type BeginUpload {
  BeginUpload(expires: Int)
}

pub type UploadHandle {
  UploadHandle(id: String)
}

pub type Progress {
  Progress(bytes_written: Int)
}

pub type Stored {
  Stored(key: String, size: Int, expires: Int)
}

pub type ByteRange {
  ByteRange(start: Int, end: Int)
}

pub type Download {
  Download(data: BitArray, total_size: Int, start: Int, end: Int)
}

pub type Error {
  TooLarge(limit: Int, actual: Int)
  QuotaExceeded(limit: Int)
  NotFound
  InvalidRange
  Unavailable(String)
}

pub type Store {
  Store(
    begin: fn(BeginUpload) -> Result(UploadHandle, Error),
    write: fn(UploadHandle, BitArray) -> Result(Progress, Error),
    finish: fn(UploadHandle) -> Result(Stored, Error),
    abort: fn(UploadHandle) -> Result(Nil, Error),
    put: fn(Upload) -> Result(Stored, Error),
    head: fn(String) -> Result(Stored, Error),
    get: fn(String, Option(ByteRange)) -> Result(Download, Error),
    list: fn() -> Result(List(Stored), Error),
    delete: fn(String) -> Result(Nil, Error),
    cleanup: fn(Int) -> Result(Int, Error),
    health: fn() -> Result(Nil, Error),
  )
}

pub fn put_in_chunks(
  store: Store,
  upload: Upload,
  chunk_bytes: Int,
) -> Result(Stored, Error) {
  use handle <- result.try(store.begin(BeginUpload(upload.expires)))
  case write_all(store, handle, upload.data, 0, max(1, chunk_bytes)) {
    Error(error) -> {
      let _ = store.abort(handle)
      Error(error)
    }
    Ok(_) ->
      case store.finish(handle) {
        Ok(stored) -> Ok(stored)
        Error(error) -> {
          let _ = store.abort(handle)
          Error(error)
        }
      }
  }
}

fn write_all(
  store: Store,
  handle: UploadHandle,
  data: BitArray,
  offset: Int,
  chunk_bytes: Int,
) -> Result(Nil, Error) {
  let total = bit_array.byte_size(data)
  case offset >= total {
    True -> Ok(Nil)
    False -> {
      let length = min(chunk_bytes, total - offset)
      use chunk <- result.try(
        bit_array.slice(data, at: offset, take: length)
        |> result.map_error(fn(_) { Unavailable("invalid upload chunk") }),
      )
      use _ <- result.try(store.write(handle, chunk))
      write_all(store, handle, data, offset + length, chunk_bytes)
    }
  }
}

pub fn content_key(data: BitArray) -> String {
  sha256_hex_bytes(data)
}

pub fn valid_content_key(key: String) -> Bool {
  let hexadecimal = "0123456789abcdef"
  string.length(key) == 64
  && key
  |> string.to_graphemes
  |> list.all(fn(character) { string.contains(hexadecimal, character) })
}

pub type Hasher

pub fn new_hasher() -> Hasher {
  sha256_init()
}

pub fn hash_chunk(hasher: Hasher, chunk: BitArray) -> Hasher {
  sha256_update(hasher, chunk)
}

pub fn finish_hash(hasher: Hasher) -> String {
  sha256_final_hex(hasher)
}

pub fn new_upload_id() -> String {
  random_id()
}

fn min(first: Int, second: Int) -> Int {
  case first < second {
    True -> first
    False -> second
  }
}

fn max(first: Int, second: Int) -> Int {
  case first > second {
    True -> first
    False -> second
  }
}

@external(erlang, "notify_ffi", "sha256_hex_bytes")
fn sha256_hex_bytes(value: BitArray) -> String

@external(erlang, "notify_ffi", "sha256_init")
fn sha256_init() -> Hasher

@external(erlang, "notify_ffi", "sha256_update")
fn sha256_update(hasher: Hasher, chunk: BitArray) -> Hasher

@external(erlang, "notify_ffi", "sha256_final_hex")
fn sha256_final_hex(hasher: Hasher) -> String

@external(erlang, "notify_ffi", "random_id")
fn random_id() -> String
