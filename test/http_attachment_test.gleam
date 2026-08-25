import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option
import gleam/string
import notify/attachment_store
import notify/attachment_store/memory as attachment_memory
import notify/core/message_json
import notify/http/router
import notify/runtime
import notify/storage/memory

fn test_runtime() -> runtime.Runtime {
  let assert Ok(messages) = memory.start()
  let assert Ok(attachments) =
    attachment_memory.start(max_file_bytes: 1024, max_total_bytes: 4096)
  runtime.new(
    storage: messages,
    clock: runtime.Clock(fn() { 1_725_000_000 }),
    ids: runtime.IdGenerator(fn() { "Attach0001XY" }),
    retention_seconds: 43_200,
  )
  |> runtime.with_attachments(
    attachments,
    base_url: "https://notify.example",
    retention_seconds: 10_800,
  )
}

pub fn local_attachment_publish_download_range_and_head_test() {
  let runtime = test_runtime()
  let upload =
    request.new()
    |> request.set_method(http.Put)
    |> request.set_path("/reports")
    |> request.set_header("filename", "report.bin")
    |> request.set_header("content-type", "application/octet-stream")
    |> request.set_body(<<0, 1, 2, 3, 4, 5>>)
    |> router.handle(runtime)
  assert upload.status == 200
  let assert Ok(body) = bit_array.to_string(upload.body)
  let assert Ok(message) = json.parse(body, message_json.decoder())
  let assert option.Some(attachment) = message.attachment
  assert attachment.name == "report.bin"
  assert attachment.size == option.Some(6)
  assert attachment.expires == option.Some(1_725_010_800)
  assert message.message == "You received a file: report.bin"

  let path = attachment.url |> string.replace("https://notify.example", "")
  let complete =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path(path)
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert complete.status == 200
  assert complete.body == <<0, 1, 2, 3, 4, 5>>
  let assert Ok(etag) = request_header(complete.headers, "etag")
  assert string.starts_with(etag, "\"")
  assert string.ends_with(etag, "\"")
  let assert Ok(disposition) =
    request_header(complete.headers, "content-disposition")
  assert string.contains(disposition, "filename*=UTF-8''report.bin")

  let not_modified =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path(path)
    |> request.set_header("if-none-match", etag)
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert not_modified.status == 304
  assert not_modified.body == <<>>
  assert request_header(not_modified.headers, "etag") == Ok(etag)

  let weak_not_modified =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path(path)
    |> request.set_header("if-none-match", "W/" <> etag)
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert weak_not_modified.status == 304

  let partial =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path(path)
    |> request.set_header("range", "bytes=1-3")
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert partial.status == 206
  assert partial.body == <<1, 2, 3>>
  assert request_header(partial.headers, "content-range") == Ok("bytes 1-3/6")

  let head =
    request.new()
    |> request.set_method(http.Head)
    |> request.set_path(path)
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert head.status == 200
  assert head.body == <<>>
  assert request_header(head.headers, "content-length") == Ok("6")
  assert request_header(head.headers, "etag") == Ok(etag)

  let forged_topic =
    path |> string.replace("/file/reports/", "/file/other-topic/")
  let denied =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path(forged_topic)
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert denied.status == 404
}

pub fn transport_can_stream_an_authorized_attachment_into_the_store_test() {
  let runtime = test_runtime()
  let incoming =
    request.new()
    |> request.set_method(http.Put)
    |> request.set_path("/streamed-reports")
    |> request.set_header("filename", "streamed.bin")
    |> request.set_header("content-type", "application/octet-stream")
    |> request.set_body(Nil)
  let assert option.Some(upload) =
    router.streamed_attachment(incoming, runtime, fn(store, expires) {
      let assert Ok(handle) =
        store.begin(attachment_store.BeginUpload(expires:))
      let assert Ok(_) = store.write(handle, <<0, 1>>)
      let assert Ok(_) = store.write(handle, <<2, 3, 4, 5>>)
      store.finish(handle)
    })
  assert upload.status == 200
  let assert Ok(encoded) = bit_array.to_string(upload.body)
  let assert Ok(published) = json.parse(encoded, message_json.decoder())
  let assert option.Some(attachment) = published.attachment
  assert attachment.size == option.Some(6)

  let path = attachment.url |> string.replace("https://notify.example", "")
  let downloaded =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path(path)
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert downloaded.status == 200
  assert downloaded.body == <<0, 1, 2, 3, 4, 5>>
}

pub fn attachment_filename_is_percent_decoded_for_content_disposition_test() {
  let runtime = test_runtime()
  let upload =
    request.new()
    |> request.set_method(http.Put)
    |> request.set_path("/reports")
    |> request.set_header("filename", "報告 1.txt")
    |> request.set_body(<<1>>)
    |> router.handle(runtime)
  let assert Ok(body) = bit_array.to_string(upload.body)
  let assert Ok(message) = json.parse(body, message_json.decoder())
  let assert option.Some(attachment) = message.attachment
  assert string.contains(attachment.url, "%E5%A0%B1%E5%91%8A%201.txt")
  let path = attachment.url |> string.replace("https://notify.example", "")
  let downloaded =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path(path)
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  let assert Ok(disposition) =
    request_header(downloaded.headers, "content-disposition")
  assert string.contains(
    disposition,
    "filename*=UTF-8''%E5%A0%B1%E5%91%8A%201.txt",
  )
}

fn request_header(headers: List(#(String, String)), name: String) {
  list.find_map(headers, fn(pair) {
    case pair.0 == name {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
}
