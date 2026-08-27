import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import http3/client
import http3/config as h3_config
import http3/server as h3_server
import http3/websocket as h3_websocket
import notify/access
import notify/attachment_store
import notify/attachment_store/filesystem
import notify/config
import notify/core/acl
import notify/doctor
import notify/http3_listener
import notify/identity/sqlite as identity_sqlite
import notify/server

pub fn required_http3_publish_and_poll_smoke_test() {
  case getenv("NOTIFY_TEST_HTTP3") {
    Ok("1") -> run_http3_smoke()
    _ -> Nil
  }
}

fn run_http3_smoke() -> Nil {
  let assert Ok(port) = available_port()
  let assert Ok(directory) = filesystem.temporary_directory()
  let database_path = directory <> "/notify.db"
  let certificate = "build/packages/http3/test/fixtures/server.pem"
  let private_key = "build/packages/http3/test/fixtures/server-key.pem"
  let assert Ok(ca_certificate) =
    pem_certificate("build/packages/http3/test/fixtures/ca.pem")
  let assert Ok(identity_sqlite.Started(identity, Some(setup_token))) =
    identity_sqlite.start(database_path, fn() { 1000 }, fn() {
      "abcdefghijklmnopqrstuvwxyz123"
    })
  let assert Ok(control) = access.managed(identity)
  let assert Ok(_) =
    access.complete_setup(
      control,
      setup_token,
      "u_http3_admin",
      "admin",
      "correct horse battery staple",
      acl.ReadWrite,
      1001,
    )
  let configuration =
    config.Config(
      ..config.defaults(),
      port:,
      base_url: Some("https://localhost:" <> int.to_string(port)),
      database_path:,
      attachment_directory: directory <> "/attachments",
      template_directory: directory <> "/templates",
      tls_certificate: certificate,
      tls_key: private_key,
      http3_mode: config.Http3Required,
    )
  let assert Ok(started) = server.start(configuration)
  let h3_client =
    client.new()
    |> client.with_address_family(h3_config.Ipv4)
    |> client.with_ca_certificate(ca_certificate)
  let assert Ok(h3_client) = h3_client
  let origin = "https://localhost:" <> int.to_string(port)
  let assert Ok(system_health_request) =
    request.to(origin <> "/api/v1/system/health")
  let h3_system_health =
    system_health_request
    |> request.set_header(
      "authorization",
      "Basic YWRtaW46Y29ycmVjdCBob3JzZSBiYXR0ZXJ5IHN0YXBsZQ==",
    )
    |> request.set_body(<<>>)
    |> client.send(h3_client, _)
  let tcp_health =
    https_get(origin <> "/healthz", "build/packages/http3/test/fixtures/ca.pem")
  let tcp_publish =
    https_post(
      origin <> "/tcp-to-h3",
      "build/packages/http3/test/fixtures/ca.pem",
      <<
        "published over tcp":utf8,
      >>,
    )
  let assert Ok(tcp_to_h3_poll_request) =
    request.to(origin <> "/tcp-to-h3/json?poll=1")
  let tcp_to_h3_poll =
    tcp_to_h3_poll_request
    |> request.set_body(<<>>)
    |> client.send(h3_client, _)
  let assert Ok(publish_request) = request.to(origin <> "/h3-smoke")
  let publish_request =
    publish_request
    |> request.set_method(http.Post)
    |> request.set_body(<<"hello over h3":utf8>>)
  let published = client.send(h3_client, publish_request)
  // Larger than one upload pull, so the HTTP/3 adapter must split the body
  // before writing it to storage.
  let attachment_payload =
    bit_array.concat(list.repeat(<<0, 1, 2, 3, 4, 5, 6, 7>>, times: 131_073))
  let attachment_key = attachment_store.content_key(attachment_payload)
  let attachment_path =
    "/file/h3-attachment/" <> attachment_key <> "/payload.bin"
  let assert Ok(attachment_request) = request.to(origin <> "/h3-attachment")
  let h3_attachment_publish =
    attachment_request
    |> request.set_method(http.Post)
    |> request.set_header("filename", "payload.bin")
    |> request.set_header("content-type", "application/octet-stream")
    |> request.set_body(attachment_payload)
    |> client.send(h3_client, _)
  let tcp_attachment_download =
    https_get(
      origin <> attachment_path,
      "build/packages/http3/test/fixtures/ca.pem",
    )
  let range_start = 1_048_570
  let range_end = 1_048_580
  let assert Ok(range_request) = request.to(origin <> attachment_path)
  let h3_attachment_range =
    range_request
    |> request.set_header(
      "range",
      "bytes=" <> int.to_string(range_start) <> "-" <> int.to_string(range_end),
    )
    |> request.set_body(<<>>)
    |> client.send(h3_client, _)
  let assert Ok(head_request) = request.to(origin <> attachment_path)
  let h3_attachment_head =
    head_request
    |> request.set_method(http.Head)
    |> request.set_body(<<>>)
    |> client.send(h3_client, _)
  let assert Ok(h3_to_tcp_publish_request) = request.to(origin <> "/h3-to-tcp")
  let h3_to_tcp_publish =
    h3_to_tcp_publish_request
    |> request.set_method(http.Post)
    |> request.set_body(<<"published over h3":utf8>>)
    |> client.send(h3_client, _)
  let h3_to_tcp_poll =
    https_get(
      origin <> "/h3-to-tcp/json?poll=1",
      "build/packages/http3/test/fixtures/ca.pem",
    )
  let assert Ok(poll_request) = request.to(origin <> "/h3-smoke/json?poll=1")
  let polled =
    poll_request
    |> request.set_body(<<>>)
    |> client.send(h3_client, _)
  let assert Ok(stream_connection) =
    client.connect(h3_client, "localhost", port)
  let assert Ok(stream_request) = request.to(origin <> "/h3-live/json")
  let assert Ok(stream) =
    stream_request
    |> request.set_body(Nil)
    |> client.open_stream(stream_connection, _)
  let assert Ok(Nil) = client.finish(stream)
  let stream_head = client.next_event(stream)
  let stream_open = client.next_event(stream)
  let assert Ok(live_publish_request) = request.to(origin <> "/h3-live")
  let live_publish =
    live_publish_request
    |> request.set_method(http.Post)
    |> request.set_body(<<"live over h3":utf8>>)
    |> client.send(h3_client, _)
  let stream_message = client.next_event(stream)
  let _ = client.cancel(stream)
  let _ = client.close(stream_connection)
  let assert Ok(websocket_connection) =
    client.connect(h3_client, "localhost", port)
  let assert Ok(websocket_request) = request.to(origin <> "/h3-ws/ws")
  let assert Ok(socket) =
    websocket_request
    |> request.set_body(Nil)
    |> h3_websocket.connect(h3_websocket.new(), websocket_connection, _)
  let websocket_open = h3_websocket.receive(socket)
  let assert Ok(#(socket, h3_websocket.TextMessage(open_message))) =
    websocket_open
  let assert Ok(websocket_publish_request) = request.to(origin <> "/h3-ws")
  let websocket_publish =
    websocket_publish_request
    |> request.set_method(http.Post)
    |> request.set_body(<<"websocket over h3":utf8>>)
    |> client.send(h3_client, _)
  let websocket_message = h3_websocket.receive(socket)
  let _ = h3_websocket.close(socket, Some(1000), "done")
  let _ = client.close(websocket_connection)
  let stopped = server.stop(started, 5000)
  let assert Ok(#(200, tcp_headers, _)) = tcp_health
  let assert Ok(#(200, _, _)) = tcp_publish
  let assert Ok(tcp_to_h3_poll) = tcp_to_h3_poll
  let assert Ok(published) = published
  let assert Ok(h3_system_health) = h3_system_health
  let assert Ok(h3_attachment_publish) = h3_attachment_publish
  let assert Ok(#(200, _, tcp_attachment_body)) = tcp_attachment_download
  let assert Ok(h3_attachment_range) = h3_attachment_range
  let assert Ok(h3_attachment_head) = h3_attachment_head
  let assert Ok(h3_to_tcp_publish) = h3_to_tcp_publish
  let assert Ok(#(200, _, h3_to_tcp_body)) = h3_to_tcp_poll
  let assert Ok(polled) = polled
  let assert Ok(client.Response(200, _)) = stream_head
  let assert Ok(client.Data(stream_open)) = stream_open
  let assert Ok(live_publish) = live_publish
  let assert Ok(client.Data(stream_message)) = stream_message
  let assert Ok(websocket_publish) = websocket_publish
  let assert Ok(#(_, h3_websocket.TextMessage(websocket_message))) =
    websocket_message
  assert stopped
  assert list.key_find(tcp_headers, "alt-svc")
    == Ok("h3=\":" <> int.to_string(port) <> "\"; ma=86400")
  assert published.status == 200
  assert h3_system_health.status == 200
  let assert Ok(system_health_body) = bit_array.to_string(h3_system_health.body)
  assert string.contains(system_health_body, "\"loopback_probe\":\"healthy\"")
  assert string.contains(system_health_body, "\"last_probe_succeeded\":true")
  assert !string.contains(system_health_body, "certificate")
  assert !string.contains(system_health_body, "private_key")
  assert h3_attachment_publish.status == 200
  assert tcp_attachment_body == attachment_payload
  assert h3_attachment_range.status == 206
  let assert Ok(expected_range) =
    bit_array.slice(
      attachment_payload,
      at: range_start,
      take: range_end - range_start + 1,
    )
  assert h3_attachment_range.body == expected_range
  assert list.key_find(h3_attachment_range.headers, "content-range")
    == Ok(
      "bytes "
      <> int.to_string(range_start)
      <> "-"
      <> int.to_string(range_end)
      <> "/"
      <> int.to_string(bit_array.byte_size(attachment_payload)),
    )
  assert h3_attachment_head.status == 200
  assert h3_attachment_head.body == <<>>
  assert list.key_find(h3_attachment_head.headers, "content-length")
    == Ok(int.to_string(bit_array.byte_size(attachment_payload)))
  assert tcp_to_h3_poll.status == 200
  assert h3_to_tcp_publish.status == 200
  assert polled.status == 200
  assert live_publish.status == 200
  assert websocket_publish.status == 200
  let assert Ok(stream_open) = bit_array.to_string(stream_open)
  let assert Ok(stream_message) = bit_array.to_string(stream_message)
  assert string.contains(stream_open, "\"event\":\"open\"")
  assert string.contains(stream_message, "live over h3")
  assert string.contains(open_message, "\"event\":\"open\"")
  assert string.contains(websocket_message, "websocket over h3")
  let assert Ok(body) = polled.body |> bit_array.to_string
  let assert Ok(tcp_to_h3_body) = tcp_to_h3_poll.body |> bit_array.to_string
  let assert Ok(h3_to_tcp_body) = bit_array.to_string(h3_to_tcp_body)
  assert string.contains(body, "hello over h3")
  assert string.contains(tcp_to_h3_body, "published over tcp")
  assert string.contains(h3_to_tcp_body, "published over h3")

  let doctor_checks = doctor.run(configuration)
  assert list.any(doctor_checks, fn(check) {
    check.component == "HTTP/3 loopback" && check.level == doctor.Pass
  })

  // Exercise the same certificate-verified exact-address probe used by
  // required startup, doctor, and the detailed system health endpoint.
  let assert Ok(probe_started) =
    http3_listener.start(configuration, fn(_, request) {
      h3_server.respond(request, 200, [], <<>>) |> result.is_ok
    })
  let probe_runtime = http3_listener.runtime(probe_started)
  assert http3_listener.probe(probe_runtime) == http3_listener.ProbeSucceeded
  let probe_snapshot = http3_listener.snapshot(probe_runtime)
  assert probe_snapshot.probe_successes >= 1
  assert probe_snapshot.last_probe_succeeded == Some(True)
  http3_listener.stop(probe_started)
}

@external(erlang, "notify_http3_test_ffi", "available_port")
fn available_port() -> Result(Int, String)

@external(erlang, "notify_http3_test_ffi", "pem_certificate")
fn pem_certificate(path: String) -> Result(BitArray, String)

@external(erlang, "notify_http3_test_ffi", "https_get")
fn https_get(
  url: String,
  ca_path: String,
) -> Result(#(Int, List(#(String, String)), BitArray), String)

@external(erlang, "notify_http3_test_ffi", "https_post")
fn https_post(
  url: String,
  ca_path: String,
  body: BitArray,
) -> Result(#(Int, List(#(String, String)), BitArray), String)

@external(erlang, "notify_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)
