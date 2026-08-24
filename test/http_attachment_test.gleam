import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/option
import gleam/string
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
    ids: runtime.IdGenerator(fn() { "Attach0001" }),
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
}

fn request_header(headers: List(#(String, String)), name: String) {
  list.find_map(headers, fn(pair) {
    case pair.0 == name {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
}
