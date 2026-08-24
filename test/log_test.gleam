import gleam/dynamic/decode
import gleam/json
import gleam/string
import notify/log

pub fn json_request_logs_are_structured_and_drop_query_secrets_test() {
  let line =
    log.request_line(
      log.Json,
      at: 1_700_000_000,
      request_id: "req-123",
      client_ip: "192.0.2.4",
      method: "POST",
      target: "/api/v1/setup?token=one-time-secret&auth=bad",
      status: 403,
      duration_ms: 8,
    )
  let assert Ok(decoded) =
    json.parse(line, {
      use event <- decode.field("event", decode.string)
      use request_id <- decode.field("request_id", decode.string)
      use path <- decode.field("path", decode.string)
      use status <- decode.field("status", decode.int)
      decode.success(#(event, request_id, path, status))
    })
  assert decoded == #("http_request", "req-123", "/api/v1/setup", 403)
  assert !string.contains(line, "one-time-secret")
  assert !string.contains(line, "auth=bad")
}

pub fn human_request_logs_cannot_be_split_by_untrusted_values_test() {
  let line =
    log.request_line(
      log.Human,
      at: 100,
      request_id: "safe\nforged",
      client_ip: "unknown",
      method: "GET",
      target: "/alerts\r\nforged?auth=secret",
      status: 200,
      duration_ms: 1,
    )
  assert !string.contains(line, "\n")
  assert !string.contains(line, "\r")
  assert !string.contains(line, "secret")
}
