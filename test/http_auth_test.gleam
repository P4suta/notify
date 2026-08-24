import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/option
import gleam/string
import notify/access
import notify/http/auth as http_auth
import notify/http/router
import notify/identity/sqlite as identity_sqlite
import notify/runtime
import notify/security/token
import notify/storage/memory

const setup_entropy = "abcdefghijklmnopqrstuvwxyz123"

fn managed_runtime() -> #(runtime.Runtime, String) {
  let assert Ok(identity_sqlite.Started(store, option.Some(setup_token))) =
    identity_sqlite.start(":memory:", fn() { 1000 }, fn() { setup_entropy })
  let assert Ok(control) = access.managed(store)
  let assert Ok(messages) = memory.start()
  let runtime =
    runtime.new(
      storage: messages,
      clock: runtime.Clock(fn() { 1001 }),
      ids: runtime.IdGenerator(fn() { "AuthId0001XY" }),
      retention_seconds: 43_200,
    )
    |> runtime.with_access(control)
  #(runtime, setup_token)
}

pub fn setup_gate_then_acl_protects_publish_and_poll_test() {
  let #(runtime, setup_token) = managed_runtime()
  let publish =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/private")
    |> request.set_body(<<"classified":utf8>>)
  assert router.handle(publish, runtime).status == 503

  let setup =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/api/v1/setup")
    |> request.set_body(bit_array.from_string(
      "{\"token\":\""
      <> setup_token
      <> "\",\"username\":\"admin\",\"password\":\"correct horse battery staple\",\"anonymous_access\":\"deny-all\"}",
    ))
    |> router.handle(runtime)
  assert setup.status == 201

  assert router.handle(publish, runtime).status == 403
  let invalid_bearer =
    publish
    |> request.set_header("authorization", "Bearer invalid")
    |> router.handle(runtime)
  assert invalid_bearer.status == 401
  let basic =
    "admin:correct horse battery staple"
    |> bit_array.from_string
    |> bit_array.base64_encode(True)
  let authenticated =
    publish
    |> request.set_header("authorization", "Basic " <> basic)
    |> router.handle(runtime)
  assert authenticated.status == 200

  let poll =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/private/json")
    |> request.set_query([#("poll", "1")])
    |> request.set_body(<<>>)
  assert router.handle(poll, runtime).status == 403
  assert router.handle(
      request.new()
        |> request.set_method(http.Get)
        |> request.set_path("/v1/health")
        |> request.set_body(<<>>),
      runtime,
    ).status
    == 200
}

pub fn invalid_bearer_falls_back_to_permitted_anonymous_acl_test() {
  let #(runtime, setup_token) = managed_runtime()
  let setup =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/api/v1/setup")
    |> request.set_body(bit_array.from_string(
      "{\"token\":\""
      <> setup_token
      <> "\",\"username\":\"admin\",\"password\":\"correct horse battery staple\",\"anonymous_access\":\"read-write\"}",
    ))
    |> router.handle(runtime)
  assert setup.status == 201

  let publish =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/public")
    |> request.set_header("authorization", "Bearer invalid")
    |> request.set_body(<<"anonymous fallback":utf8>>)
    |> router.handle(runtime)
  assert publish.status == 200
}

pub fn websocket_auth_query_decodes_like_ntfy_test() {
  let encoded_basic =
    "admin:password"
    |> bit_array.from_string
    |> bit_array.base64_encode(True)
  let header = "Basic " <> encoded_basic
  let encoded = header |> bit_array.from_string |> bit_array.base64_encode(True)
  let req =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/topic/ws")
    |> request.set_query([#("auth", encoded)])
    |> request.set_body(<<>>)
  assert http_auth.credentials(req) == Ok(access.Basic("admin", "password"))
}

pub fn session_csrf_requires_the_exact_derived_digest_test() {
  let session = "tk_abcdefghijklmnopqrstuvwxyz123"
  let expected = token.digest("csrf:" <> session)
  let base =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/api/v1/users")
    |> request.set_header("cookie", "other=x; notify_session=" <> session)
    |> request.set_body(<<>>)

  assert base
    |> request.set_header("x-csrf-token", expected)
    |> http_auth.valid_csrf
  let changed =
    base
    |> request.set_header("x-csrf-token", "0" <> string.drop_start(expected, 1))
    |> http_auth.valid_csrf
  assert changed == False
  let extended =
    base
    |> request.set_header("x-csrf-token", expected <> "0")
    |> http_auth.valid_csrf
  assert extended == False
}
