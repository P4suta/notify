import gleam/int
import gleam/io
import gleam/json
import gleam/string

pub type Format {
  Human
  Json
}

pub fn request_line(
  format: Format,
  at at: Int,
  request_id request_id: String,
  client_ip client_ip: String,
  method method: String,
  target target: String,
  status status: Int,
  duration_ms duration_ms: Int,
) -> String {
  let request_id = single_line(request_id)
  let client_ip = single_line(client_ip)
  let method = single_line(method)
  let path = target |> without_query |> single_line
  case format {
    Json ->
      json.object([
        #("time", json.int(at)),
        #("level", json.string("info")),
        #("event", json.string("http_request")),
        #("request_id", json.string(request_id)),
        #("client_ip", json.string(client_ip)),
        #("method", json.string(method)),
        #("path", json.string(path)),
        #("status", json.int(status)),
        #("duration_ms", json.int(duration_ms)),
      ])
      |> json.to_string
    Human ->
      "time="
      <> int.to_string(at)
      <> " level=info event=http_request request_id="
      <> request_id
      <> " client_ip="
      <> client_ip
      <> " method="
      <> method
      <> " path="
      <> path
      <> " status="
      <> int.to_string(status)
      <> " duration_ms="
      <> int.to_string(duration_ms)
  }
}

pub fn request(
  format: Format,
  at at: Int,
  request_id request_id: String,
  client_ip client_ip: String,
  method method: String,
  target target: String,
  status status: Int,
  duration_ms duration_ms: Int,
) -> Nil {
  request_line(
    format,
    at:,
    request_id:,
    client_ip:,
    method:,
    target:,
    status:,
    duration_ms:,
  )
  |> io.println
}

fn without_query(target: String) -> String {
  target |> before("?") |> before("#")
}

fn before(value: String, delimiter: String) -> String {
  case string.split_once(value, delimiter) {
    Ok(#(prefix, _)) -> prefix
    Error(_) -> value
  }
}

fn single_line(value: String) -> String {
  value
  |> string.replace("\r\n", "\\r\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\n", "\\n")
}
