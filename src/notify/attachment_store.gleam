import gleam/option.{type Option}

pub type Upload {
  Upload(data: BitArray, expires: Int)
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
    put: fn(Upload) -> Result(Stored, Error),
    head: fn(String) -> Result(Stored, Error),
    get: fn(String, Option(ByteRange)) -> Result(Download, Error),
    list: fn() -> Result(List(Stored), Error),
    delete: fn(String) -> Result(Nil, Error),
    cleanup: fn(Int) -> Result(Int, Error),
    health: fn() -> Result(Nil, Error),
  )
}

pub fn content_key(data: BitArray) -> String {
  sha256_hex_bytes(data)
}

@external(erlang, "notify_ffi", "sha256_hex_bytes")
fn sha256_hex_bytes(value: BitArray) -> String
