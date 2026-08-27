import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
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

pub type Page(a) {
  Page(items: List(a), has_more: Bool)
}

pub type ByteRange {
  ByteRange(start: Int, end: Int)
}

pub type Download {
  Download(data: BitArray, total_size: Int, start: Int, end: Int)
}

/// One finite pull from an open attachment download.
pub type DownloadRead {
  DownloadChunk(BitArray)
  DownloadEnd
}

type DownloadSource

/// An explicitly closeable attachment download cursor.
pub opaque type DownloadHandle {
  DownloadHandle(source: DownloadSource, total_size: Int, start: Int, end: Int)
}

/// Maximum chunk accepted by the cross-transport download port.
pub const maximum_download_chunk_bytes = 1_048_576

pub type Error {
  TooLarge(limit: Int, actual: Int)
  QuotaExceeded(limit: Int)
  NotFound
  InvalidRange
  InvalidPage
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
    open: fn(String, Option(ByteRange)) -> Result(DownloadHandle, Error),
    list: fn() -> Result(List(Stored), Error),
    page: fn(Option(String), Int) -> Result(Page(Stored), Error),
    delete: fn(String) -> Result(Nil, Error),
    cleanup: fn(Int) -> Result(Int, Error),
    health: fn() -> Result(Nil, Error),
  )
}

/// Open a cursor over a backend download without changing its range metadata.
pub fn open_download(download: Download) -> DownloadHandle {
  DownloadHandle(
    source: open_binary_download(download.data),
    total_size: download.total_size,
    start: download.start,
    end: download.end,
  )
}

/// Open a bounded pull cursor backed by a range reader.
///
/// `read_at` is invoked only with a positive length no greater than the
/// caller's requested chunk size. The cursor owns the offset and invokes
/// `cleanup` when it is closed or when its opening process terminates.
pub fn open_reader(
  total_size: Int,
  start: Int,
  end: Int,
  read_at: fn(Int, Int) -> Result(BitArray, Error),
  cleanup: fn() -> Nil,
) -> DownloadHandle {
  DownloadHandle(
    source: open_range_download(read_at, cleanup, start, end),
    total_size:,
    start:,
    end:,
  )
}

/// Resolve and validate the inclusive bounds for an attachment download.
pub fn download_bounds(
  total_size: Int,
  range: Option(ByteRange),
) -> Result(#(Int, Int), Error) {
  case total_size, range {
    0, None -> Ok(#(0, -1))
    0, Some(_) -> Error(InvalidRange)
    _, _ -> {
      let #(start, end) = case range {
        None -> #(0, total_size - 1)
        Some(ByteRange(start, end)) -> #(start, end)
      }
      case start < 0 || end < start || end >= total_size {
        True -> Error(InvalidRange)
        False -> Ok(#(start, end))
      }
    }
  }
}

/// Read at most one MiB from an open attachment cursor.
pub fn read(
  handle: DownloadHandle,
  maximum_bytes: Int,
) -> Result(DownloadRead, Error) {
  case maximum_bytes >= 1 && maximum_bytes <= maximum_download_chunk_bytes {
    False ->
      Error(Unavailable(
        "attachment download chunk must be between 1 byte and 1 MiB",
      ))
    True ->
      case read_binary_download(handle.source, maximum_bytes) {
        Error(_) -> Error(Unavailable("attachment download stream unavailable"))
        Ok(#(1, bytes)) -> Ok(DownloadChunk(bytes))
        Ok(#(2, _)) -> Ok(DownloadEnd)
        Ok(_) -> Error(Unavailable("attachment download stream unavailable"))
      }
  }
}

/// Idempotently close an attachment download and release backend resources.
pub fn close(handle: DownloadHandle) -> Nil {
  close_binary_download(handle.source)
}

/// Return the complete object size before range selection.
pub fn download_total_size(handle: DownloadHandle) -> Int {
  handle.total_size
}

/// Return the inclusive first byte selected for this download.
pub fn download_start(handle: DownloadHandle) -> Int {
  handle.start
}

/// Return the inclusive final byte selected for this download.
pub fn download_end(handle: DownloadHandle) -> Int {
  handle.end
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

pub fn valid_page(after: Option(String), limit: Int) -> Bool {
  limit >= 1
  && limit <= 100
  && case after {
    None -> True
    Some(key) -> valid_content_key(key)
  }
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

@external(erlang, "notify_attachment_stream_ffi", "open_binary")
fn open_binary_download(data: BitArray) -> DownloadSource

@external(erlang, "notify_attachment_stream_ffi", "open_reader")
fn open_range_download(
  read_at: fn(Int, Int) -> Result(BitArray, Error),
  cleanup: fn() -> Nil,
  start: Int,
  end: Int,
) -> DownloadSource

@external(erlang, "notify_attachment_stream_ffi", "read")
fn read_binary_download(
  source: DownloadSource,
  maximum_bytes: Int,
) -> Result(#(Int, BitArray), String)

@external(erlang, "notify_attachment_stream_ffi", "close")
fn close_binary_download(source: DownloadSource) -> Nil
