import gleam/http
import gleam/http/request
import gleam/option.{Some}
import notify/http/h3

pub fn request_parts_preserve_h3_origin_target_headers_and_body_test() {
  let assert Ok(converted) =
    h3.request_from_parts(
      http.Post,
      "https",
      "notify.example:8443",
      "/alerts?title=hello",
      [#("Authorization", "Bearer token"), #("x-forwarded-for", "bad")],
      <<"payload":utf8>>,
    )
  assert converted.method == http.Post
  assert converted.scheme == http.Https
  assert converted.host == "notify.example"
  assert converted.port == Some(8443)
  assert converted.path == "/alerts"
  assert converted.query == Some("title=hello")
  assert converted.body == <<"payload":utf8>>
  assert request.get_header(converted, "authorization") == Ok("Bearer token")
  assert request.get_header(converted, "x-forwarded-for") == Ok("bad")
}

pub fn request_parts_accept_bracketed_ipv6_authority_test() {
  let assert Ok(converted) =
    h3.request_from_parts(
      http.Get,
      "https",
      "[2001:db8::1]:443",
      "/healthz",
      [],
      <<>>,
    )
  assert converted.host == "2001:db8::1"
  assert converted.port == Some(443)
  assert converted.path == "/healthz"
}

pub fn request_parts_reject_invalid_authority_test() {
  assert h3.request_from_parts(
      http.Get,
      "https",
      "bad authority",
      "/healthz",
      [],
      <<>>,
    )
    == Error(Nil)
}
