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

pub fn memory_attachment_store_contract_test() {
  let assert Ok(store) = memory.start(max_file_bytes: 10, max_total_bytes: 20)
  contract(store)
}

pub fn filesystem_attachment_store_contract_test() {
  let assert Ok(directory) = filesystem.temporary_directory()
  let assert Ok(store) =
    filesystem.start(directory, max_file_bytes: 10, max_total_bytes: 20)
  contract(store)
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
      contract(store)
    }
  }
}

@external(erlang, "notify_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)
