import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import notify/attachment_store
import notify/attachment_store/filesystem
import notify/attachment_store/memory
import notify/attachment_store/s3

fn contract(store: attachment_store.Store) {
  let upload = attachment_store.Upload(<<"abcdef":utf8>>, expires: 100)
  let assert Ok(stored) = store.put(upload)
  assert stored.size == 6
  assert string.length(stored.key) == 64
  assert store.list() == Ok([stored])

  let assert Ok(complete) = store.get(stored.key, None)
  assert complete.data == <<"abcdef":utf8>>
  assert complete.total_size == 6
  assert complete.start == 0
  assert complete.end == 5

  let assert Ok(partial) =
    store.get(stored.key, Some(attachment_store.ByteRange(1, 3)))
  assert partial.data == <<"bcd":utf8>>
  assert partial.total_size == 6
  assert partial.start == 1
  assert partial.end == 3
  assert store.get(stored.key, Some(attachment_store.ByteRange(4, 9)))
    == Error(attachment_store.InvalidRange)

  let assert Ok(same) = store.put(upload)
  assert same.key == stored.key
  assert store.cleanup(99) == Ok(0)
  assert store.cleanup(100) == Ok(1)
  assert store.list() == Ok([])
  assert store.get(stored.key, None) == Error(attachment_store.NotFound)
}

fn streaming_contract(store: attachment_store.Store) {
  let assert Ok(handle) =
    store.begin(attachment_store.BeginUpload(expires: 120))
  assert store.write(handle, <<"ab":utf8>>)
    == Ok(attachment_store.Progress(bytes_written: 2))
  assert store.write(handle, <<"cdef":utf8>>)
    == Ok(attachment_store.Progress(bytes_written: 6))
  let assert Ok(stored) = store.finish(handle)
  assert stored.key == attachment_store.content_key(<<"abcdef":utf8>>)
  assert stored.size == 6
  assert stored.expires == 120
  let assert Ok(download) = store.get(stored.key, None)
  assert download.data == <<"abcdef":utf8>>

  let assert Ok(duplicate) =
    attachment_store.put_in_chunks(
      store,
      attachment_store.Upload(<<"abcdef":utf8>>, expires: 150),
      2,
    )
  assert duplicate.key == stored.key
  assert duplicate.expires == 150
  assert store.list() == Ok([duplicate])

  let assert Ok(aborted) =
    store.begin(attachment_store.BeginUpload(expires: 200))
  let assert Ok(_) = store.write(aborted, <<"discard":utf8>>)
  assert store.abort(aborted) == Ok(Nil)
  assert store.abort(aborted) == Ok(Nil)
  assert store.finish(aborted) == Error(attachment_store.NotFound)
  assert store.list() == Ok([duplicate])
}

fn orphan_grace_contract(store: attachment_store.Store) {
  let assert Ok(handle) =
    store.begin(attachment_store.BeginUpload(expires: unix_seconds() + 7200))
  let assert Ok(_) = store.write(handle, <<"orphan":utf8>>)
  let assert Ok(_) = store.cleanup(unix_seconds() + 3601)
  assert store.finish(handle) == Error(attachment_store.NotFound)
}

fn empty_stream_contract(store: attachment_store.Store) {
  let assert Ok(handle) =
    store.begin(attachment_store.BeginUpload(expires: 180))
  let assert Ok(stored) = store.finish(handle)
  assert stored.size == 0
  assert stored.key == attachment_store.content_key(<<>>)
  let assert Ok(download) = store.get(stored.key, None)
  assert download.data == <<>>
  assert download.total_size == 0
  assert download.end == -1
  assert store.get(
      stored.key,
      Some(attachment_store.ByteRange(start: 0, end: 0)),
    )
    == Error(attachment_store.InvalidRange)
  assert store.delete(stored.key) == Ok(Nil)
}

fn management_page_contract(store: attachment_store.Store) {
  let assert Ok(existing) = store.list()
  list.each(existing, fn(item) {
    assert store.delete(item.key) == Ok(Nil)
  })
  let assert Ok(first) =
    store.put(attachment_store.Upload(<<"page-a":utf8>>, expires: 300))
  let assert Ok(second) =
    store.put(attachment_store.Upload(<<"page-b":utf8>>, expires: 301))
  let assert Ok(third) =
    store.put(attachment_store.Upload(<<"page-c":utf8>>, expires: 302))
  let expected =
    [first, second, third]
    |> list.sort(fn(left, right) { string.compare(left.key, right.key) })

  let assert Ok(attachment_store.Page(first_page, True)) = store.page(None, 2)
  assert first_page == list.take(expected, 2)
  let assert Ok(after) = list.last(first_page)
  let assert Ok(attachment_store.Page(second_page, False)) =
    store.page(Some(after.key), 2)
  assert second_page == list.drop(expected, 2)

  assert store.page(None, 0) == Error(attachment_store.InvalidPage)
  assert store.page(None, 101) == Error(attachment_store.InvalidPage)
  assert store.page(Some("not-a-content-key"), 2)
    == Error(attachment_store.InvalidPage)

  list.each(expected, fn(item) {
    assert store.delete(item.key) == Ok(Nil)
  })
}

pub fn memory_attachment_store_contract_test() {
  let assert Ok(store) = memory.start(max_file_bytes: 10, max_total_bytes: 20)
  contract(store)
  streaming_contract(store)
  empty_stream_contract(store)
  orphan_grace_contract(store)
  management_page_contract(store)
}

pub fn filesystem_attachment_store_contract_test() {
  let assert Ok(directory) = filesystem.temporary_directory()
  let assert Ok(store) =
    filesystem.start(directory, max_file_bytes: 10, max_total_bytes: 20)
  contract(store)
  streaming_contract(store)
  empty_stream_contract(store)
  orphan_grace_contract(store)
  management_page_contract(store)
}

pub fn filesystem_exposes_only_valid_content_addressed_blob_paths_test() {
  let assert Ok(directory) = filesystem.temporary_directory()
  let key = attachment_store.content_key(<<"safe path":utf8>>)
  let assert Ok(path) = filesystem.blob_path(directory, key)
  assert string.ends_with(path, key <> ".blob")
  assert filesystem.blob_path(directory, "../outside")
    == Error(attachment_store.NotFound)
}

fn concurrent_quota_contract(store: attachment_store.Store) {
  let assert Ok(first) = store.begin(attachment_store.BeginUpload(100))
  let assert Ok(second) = store.begin(attachment_store.BeginUpload(100))
  let assert Ok(_) = store.write(first, <<"123456":utf8>>)
  let assert Ok(_) = store.write(second, <<"abcdef":utf8>>)
  let assert Ok(_) = store.finish(first)
  assert store.finish(second) == Error(attachment_store.QuotaExceeded(10))
  assert store.abort(second) == Ok(Nil)
}

pub fn streaming_attachment_quota_is_committed_atomically_test() {
  let assert Ok(memory_store) =
    memory.start(max_file_bytes: 10, max_total_bytes: 10)
  concurrent_quota_contract(memory_store)
  let assert Ok(directory) = filesystem.temporary_directory()
  let assert Ok(filesystem_store) =
    filesystem.start(directory, max_file_bytes: 10, max_total_bytes: 10)
  concurrent_quota_contract(filesystem_store)
}

pub fn oversized_stream_is_aborted_before_promotion_test() {
  let assert Ok(store) = memory.start(max_file_bytes: 5, max_total_bytes: 10)
  let assert Ok(handle) = store.begin(attachment_store.BeginUpload(100))
  assert store.write(handle, <<"123456":utf8>>)
    == Error(attachment_store.TooLarge(5, 6))
  assert store.finish(handle) == Error(attachment_store.NotFound)
  assert store.list() == Ok([])
}

pub fn attachment_size_and_total_quota_are_enforced_test() {
  let assert Ok(store) = memory.start(max_file_bytes: 6, max_total_bytes: 8)
  assert store.put(attachment_store.Upload(<<0, 1, 2, 3, 4, 5, 6>>, 100))
    == Error(attachment_store.TooLarge(6, 7))
  let assert Ok(_) = store.put(attachment_store.Upload(<<0, 1, 2, 3, 4>>, 100))
  assert store.put(attachment_store.Upload(<<5, 6, 7, 8>>, 100))
    == Error(attachment_store.QuotaExceeded(8))
}

pub fn s3_compatible_attachment_store_contract_test() {
  case getenv("NOTIFY_TEST_S3_ENDPOINT") {
    Error(_) -> Nil
    Ok(endpoint) -> {
      let access_key =
        getenv("NOTIFY_TEST_S3_ACCESS_KEY")
        |> result.unwrap("notify-access")
      let secret_key =
        getenv("NOTIFY_TEST_S3_SECRET_KEY")
        |> result.unwrap("notify-secret-password")
      let assert Ok(store) =
        s3.start(
          s3.Config(
            endpoint:,
            bucket: "notify",
            region: "us-east-1",
            access_key:,
            secret_key:,
            path_style: True,
          ),
          max_file_bytes: 10,
          max_total_bytes: 20,
        )
      let small_key = attachment_store.content_key(<<"abcdef":utf8>>)
      let assert Ok(_) = store.delete(small_key)
      contract(store)
      streaming_contract(store)
      empty_stream_contract(store)
      let assert Ok(_) = store.delete(small_key)

      let large =
        string.repeat("x", times: 5_242_880)
        |> bit_array.from_string
      let assert Ok(multipart_store) =
        s3.start(
          s3.Config(
            endpoint:,
            bucket: "notify",
            region: "us-east-1",
            access_key:,
            secret_key:,
            path_style: True,
          ),
          max_file_bytes: 6_000_000,
          max_total_bytes: 12_000_000,
        )
      let assert Ok(upload) =
        multipart_store.begin(attachment_store.BeginUpload(expires: 300))
      assert multipart_store.write(upload, large)
        == Ok(attachment_store.Progress(bytes_written: 5_242_880))
      assert multipart_store.write(upload, <<"yz":utf8>>)
        == Ok(attachment_store.Progress(bytes_written: 5_242_882))
      let assert Ok(stored) = multipart_store.finish(upload)
      assert stored.size == 5_242_882
      let assert Ok(boundary) =
        multipart_store.get(
          stored.key,
          Some(attachment_store.ByteRange(5_242_879, 5_242_881)),
        )
      assert boundary.data == <<"xyz":utf8>>
      let assert Ok(_) = multipart_store.delete(stored.key)
      orphan_grace_contract(multipart_store)
      management_page_contract(multipart_store)
    }
  }
}

@external(erlang, "notify_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)

@external(erlang, "notify_ffi", "unix_seconds")
fn unix_seconds() -> Int
