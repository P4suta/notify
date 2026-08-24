import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/option.{Some}
import gleam/string
import notify/access
import notify/attachment_store
import notify/attachment_store/memory as attachment_memory
import notify/delivery
import notify/delivery/memory as delivery_memory
import notify/http/router
import notify/identity/sqlite as identity_sqlite
import notify/runtime
import notify/storage/memory as storage_memory
import notify/webpush
import notify/webpush/memory as webpush_memory

const setup_entropy = "abcdefghijklmnopqrstuvwxyz123"

fn managed_runtime() -> #(runtime.Runtime, String) {
  let assert Ok(identity_sqlite.Started(store, Some(setup_token))) =
    identity_sqlite.start(":memory:", fn() { 1000 }, fn() { setup_entropy })
  let assert Ok(control) = access.managed(store)
  let assert Ok(messages) = storage_memory.start()
  let assert Ok(deliveries) = delivery_memory.start()
  #(
    runtime.new(
      storage: messages,
      clock: runtime.Clock(fn() { 1001 }),
      ids: runtime.secure_ids(),
      retention_seconds: 43_200,
    )
      |> runtime.with_access(control)
      |> runtime.with_deliveries(deliveries),
    setup_token,
  )
}

fn complete_setup(runtime: runtime.Runtime, setup_token: String) {
  let response =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/api/v1/setup")
    |> request.set_body(bit_array.from_string(
      "{\"token\":\""
      <> setup_token
      <> "\",\"username\":\"admin\",\"password\":\"correct horse battery staple\",\"anonymous_access\":\"deny\"}",
    ))
    |> router.handle(runtime)
  assert response.status == 201
}

fn admin_header() -> String {
  "admin:correct horse battery staple"
  |> bit_array.from_string
  |> bit_array.base64_encode(True)
  |> fn(value) { "Basic " <> value }
}

fn admin_request(method: http.Method, path: String, body: String) {
  request.new()
  |> request.set_method(method)
  |> request.set_path(path)
  |> request.set_header("authorization", admin_header())
  |> request.set_body(bit_array.from_string(body))
}

pub fn one_time_setup_url_serves_a_csp_protected_page_test() {
  let #(runtime, _) = managed_runtime()
  let response =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/setup")
    |> request.set_query([#("token", setup_entropy)])
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert response.status == 200
  let assert Ok(csp) = response.get_header(response, "content-security-policy")
  assert string.contains(csp, "default-src 'self'")
  let assert Ok(body) = bit_array.to_string(response.body)
  assert string.contains(body, "Create the first administrator")
}

pub fn admin_user_token_and_acl_api_never_lists_raw_secrets_test() {
  let #(runtime, setup_token) = managed_runtime()
  complete_setup(runtime, setup_token)

  let created =
    admin_request(
      http.Post,
      "/api/v1/users",
      "{\"username\":\"pat\",\"password\":\"a different secure password\",\"role\":\"user\"}",
    )
    |> router.handle(runtime)
  assert created.status == 201

  let listed =
    admin_request(http.Get, "/api/v1/users", "")
    |> router.handle(runtime)
  assert listed.status == 200
  let assert Ok(list_body) = bit_array.to_string(listed.body)
  assert string.contains(list_body, "\"username\":\"pat\"")
  assert !string.contains(list_body, "different secure password")
  assert !string.contains(list_body, "password_hash")

  let grant =
    admin_request(
      http.Put,
      "/api/v1/acl",
      "{\"username\":\"pat\",\"topic_pattern\":\"jobs-*\",\"permission\":\"read-write\"}",
    )
    |> router.handle(runtime)
  assert grant.status == 200

  let pat_basic =
    "pat:a different secure password"
    |> bit_array.from_string
    |> bit_array.base64_encode(True)
  let publish =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/jobs-nightly")
    |> request.set_header("authorization", "Basic " <> pat_basic)
    |> request.set_body(<<"done":utf8>>)
    |> router.handle(runtime)
  assert publish.status == 200

  let token_response =
    admin_request(
      http.Post,
      "/api/v1/tokens",
      "{\"username\":\"pat\",\"label\":\"automation\"}",
    )
    |> router.handle(runtime)
  assert token_response.status == 201
  let assert Ok(token_body) = bit_array.to_string(token_response.body)
  let assert Ok(raw) =
    json.parse(token_body, {
      use raw <- decode.field("token", decode.string)
      decode.success(raw)
    })
  assert string.starts_with(raw, "tk_")

  let tokens =
    admin_request(http.Get, "/api/v1/tokens", "")
    |> request.set_query([#("username", "pat")])
    |> router.handle(runtime)
  let assert Ok(tokens_body) = bit_array.to_string(tokens.body)
  assert tokens.status == 200
  assert string.contains(tokens_body, "tk_")
  assert !string.contains(tokens_body, raw)

  let last_admin =
    admin_request(http.Delete, "/api/v1/users/admin", "")
    |> router.handle(runtime)
  assert last_admin.status == 409
}

pub fn web_session_is_httponly_and_mutations_require_csrf_test() {
  let #(runtime, setup_token) = managed_runtime()
  complete_setup(runtime, setup_token)
  let login =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/api/v1/session")
    |> request.set_body(<<
      "{\"username\":\"admin\",\"password\":\"correct horse battery staple\"}":utf8,
    >>)
    |> router.handle(runtime)
  assert login.status == 201
  let assert Ok(cookie_header) = response.get_header(login, "set-cookie")
  assert string.contains(cookie_header, "Secure")
  assert string.contains(cookie_header, "HttpOnly")
  assert string.contains(cookie_header, "SameSite=Strict")
  let cookie =
    cookie_header
    |> string.split(";")
    |> list_first
  let assert Ok(login_body) = bit_array.to_string(login.body)
  let assert Ok(csrf) =
    json.parse(login_body, {
      use csrf <- decode.field("csrf_token", decode.string)
      decode.success(csrf)
    })

  let without_csrf =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/api/v1/users")
    |> request.set_header("cookie", cookie)
    |> request.set_body(<<
      "{\"username\":\"nope\",\"password\":\"a sufficiently long password\"}":utf8,
    >>)
    |> router.handle(runtime)
  assert without_csrf.status == 403

  let with_csrf =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/api/v1/users")
    |> request.set_header("cookie", cookie)
    |> request.set_header("x-csrf-token", csrf)
    |> request.set_body(<<
      "{\"username\":\"casey\",\"password\":\"a sufficiently long password\"}":utf8,
    >>)
    |> router.handle(runtime)
  assert with_csrf.status == 201

  let logout =
    request.new()
    |> request.set_method(http.Delete)
    |> request.set_path("/api/v1/session")
    |> request.set_header("cookie", cookie)
    |> request.set_header("x-csrf-token", csrf)
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert logout.status == 204
}

pub fn admin_can_inspect_delivery_failures_without_payload_content_test() {
  let #(runtime, setup_token) = managed_runtime()
  complete_setup(runtime, setup_token)
  let assert Some(outbox) = runtime.deliveries
  let assert Ok(_) =
    outbox.enqueue(delivery.NewJob(
      id: "job-visible",
      kind: delivery.MobileRelay,
      endpoint: "https://relay.example/secret-endpoint",
      payload: <<"private message body":utf8>>,
      message_id: "Message001",
      topic_hash: "safe-hash",
      available_at: 1000,
    ))
  let response =
    admin_request(http.Get, "/api/v1/delivery-jobs", "")
    |> router.handle(runtime)
  assert response.status == 200
  let assert Ok(body) = bit_array.to_string(response.body)
  assert string.contains(body, "job-visible")
  assert string.contains(body, "mobile_relay")
  assert !string.contains(body, "private message body")
  assert !string.contains(body, "secret-endpoint")
}

pub fn deleting_a_user_removes_their_webpush_subscriptions_test() {
  let #(initial, setup_token) = managed_runtime()
  let assert Ok(subscriptions) = webpush_memory.start(max_endpoints_per_ip: 10)
  let runtime =
    initial
    |> runtime.with_webpush(runtime.WebPushRuntime(
      store: subscriptions,
      public_key: "public",
      private_key: "private",
      subscriber: "admin@example.test",
    ))
  complete_setup(runtime, setup_token)
  let created =
    admin_request(
      http.Post,
      "/api/v1/users",
      "{\"username\":\"pat\",\"password\":\"a different secure password\",\"role\":\"user\"}",
    )
    |> router.handle(runtime)
  assert created.status == 201
  let endpoint =
    "https://updates.push.services.mozilla.com/wpush/v2/user-delete"
  let assert Ok(_) =
    subscriptions.upsert(webpush.NewSubscription(
      id: "wps_pat",
      endpoint:,
      auth: "kSC3T8aN1JCQxxPdrFLrZg",
      p256dh: "BMKKbxdUU_xLS7G1Wh5AN8PvWOjCzkCuKZYb8apcqYrDxjOF_2piggBnoJLQYx9IeSD70fNuwawI3e9Y8m3S3PE",
      topics: ["alerts"],
      user_id: Some("pat"),
      subscriber_ip: "192.0.2.1",
      now: 1001,
    ))
  let deleted =
    admin_request(http.Delete, "/api/v1/users/pat", "")
    |> router.handle(runtime)
  assert deleted.status == 204
  assert subscriptions.by_endpoint(endpoint) == Error(webpush.NotFound)
}

pub fn admin_can_list_and_delete_attachments_without_reading_the_body_test() {
  let #(initial, setup_token) = managed_runtime()
  let assert Ok(attachments) =
    attachment_memory.start(max_file_bytes: 1024, max_total_bytes: 4096)
  let runtime =
    runtime.with_attachments(
      initial,
      attachments,
      base_url: "https://notify.example",
      retention_seconds: 3600,
    )
  complete_setup(runtime, setup_token)
  let assert Ok(stored) =
    attachments.put(attachment_store.Upload(<<"private attachment":utf8>>, 5000))

  let listed =
    admin_request(http.Get, "/api/v1/attachments", "")
    |> router.handle(runtime)
  assert listed.status == 200
  let assert Ok(body) = bit_array.to_string(listed.body)
  assert string.contains(body, stored.key)
  assert string.contains(body, "\"size\":18")
  assert !string.contains(body, "private attachment")

  let deleted =
    admin_request(http.Delete, "/api/v1/attachments/" <> stored.key, "")
    |> router.handle(runtime)
  assert deleted.status == 204
  assert attachments.head(stored.key) == Error(attachment_store.NotFound)
}

fn list_first(values: List(String)) -> String {
  case values {
    [first, ..] -> first
    [] -> ""
  }
}
