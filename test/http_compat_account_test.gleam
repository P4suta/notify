import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/json
import gleam/option.{Some}
import gleam/string
import notify/access
import notify/http/router
import notify/identity/sqlite as identity_sqlite
import notify/runtime
import notify/storage/memory

const setup_entropy = "abcdefghijklmnopqrstuvwxyz123"

fn managed_runtime() -> #(runtime.Runtime, String) {
  let assert Ok(identity_sqlite.Started(store, Some(setup_token))) =
    identity_sqlite.start(":memory:", fn() { 1000 }, fn() { setup_entropy })
  let assert Ok(control) = access.managed(store)
  let assert Ok(messages) = memory.start()
  #(
    runtime.new(
      storage: messages,
      clock: runtime.Clock(fn() { 1001 }),
      ids: runtime.secure_ids(),
      retention_seconds: 43_200,
    )
      |> runtime.with_access(control),
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

fn authorization(username: String, password: String) -> String {
  let credentials = username <> ":" <> password
  credentials
  |> bit_array.from_string
  |> bit_array.base64_encode(True)
  |> fn(value) { "Basic " <> value }
}

fn api_request(
  method: http.Method,
  path: String,
  body: String,
  authorization_header: String,
) {
  request.new()
  |> request.set_method(method)
  |> request.set_path(path)
  |> request.set_header("authorization", authorization_header)
  |> request.set_body(bit_array.from_string(body))
}

fn response_text(response: Response(BitArray)) -> String {
  let assert Ok(body) = bit_array.to_string(response.body)
  body
}

pub fn ntfy_account_login_token_revoke_and_password_contract_test() {
  let #(runtime, setup_token) = managed_runtime()
  complete_setup(runtime, setup_token)

  let anonymous =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/v1/account")
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert anonymous.status == 200
  assert string.contains(response_text(anonymous), "\"username\":\"*\"")
  assert string.contains(response_text(anonymous), "\"role\":\"anonymous\"")

  let admin_basic = authorization("admin", "correct horse battery staple")
  let login =
    api_request(http.Post, "/v1/account/login", "", admin_basic)
    |> router.handle(runtime)
  assert login.status == 200
  let assert Ok(#(login_token, username)) =
    json.parse(response_text(login), {
      use token <- decode.field("token", decode.string)
      use username <- decode.field("username", decode.string)
      decode.success(#(token, username))
    })
  assert username == "admin"
  assert string.starts_with(login_token, "tk_")

  let bearer = "Bearer " <> login_token
  let account =
    api_request(http.Get, "/v1/account", "", bearer)
    |> router.handle(runtime)
  assert account.status == 200
  assert string.contains(response_text(account), "\"username\":\"admin\"")
  assert !string.contains(response_text(account), login_token)

  let issued =
    api_request(
      http.Post,
      "/v1/account/token",
      "{\"label\":\"phone\",\"expires\":2000}",
      bearer,
    )
    |> router.handle(runtime)
  assert issued.status == 200
  let assert Ok(api_token) =
    json.parse(response_text(issued), {
      use token <- decode.field("token", decode.string)
      decode.success(token)
    })
  assert string.starts_with(api_token, "tk_")

  let revoked =
    api_request(http.Delete, "/v1/account/token", "", admin_basic)
    |> request.set_header("x-token", api_token)
    |> router.handle(runtime)
  assert revoked.status == 200
  assert response_text(revoked) == "{\"success\":true}"
  assert api_request(http.Get, "/v1/account", "", "Bearer " <> api_token)
    |> router.handle(runtime)
    |> fn(response) { response.status }
    == 401

  let password_changed =
    api_request(
      http.Post,
      "/v1/account/password",
      "{\"password\":\"correct horse battery staple\",\"new_password\":\"another secure password\"}",
      bearer,
    )
    |> router.handle(runtime)
  assert password_changed.status == 200
  assert api_request(
      http.Post,
      "/v1/account/login",
      "",
      authorization("admin", "another secure password"),
    )
    |> router.handle(runtime)
    |> fn(response) { response.status }
    == 200
}

pub fn ntfy_admin_users_and_access_contract_test() {
  let #(runtime, setup_token) = managed_runtime()
  complete_setup(runtime, setup_token)
  let admin = authorization("admin", "correct horse battery staple")

  let created =
    api_request(
      http.Post,
      "/v1/users",
      "{\"username\":\"pat\",\"password\":\"a different secure password\"}",
      admin,
    )
    |> router.handle(runtime)
  assert created.status == 200
  assert response_text(created) == "{\"success\":true}"

  let granted =
    api_request(
      http.Post,
      "/v1/users/access",
      "{\"username\":\"pat\",\"topic\":\"jobs-*\",\"permission\":\"ro\"}",
      admin,
    )
    |> router.handle(runtime)
  assert granted.status == 200

  let listed =
    api_request(http.Get, "/v1/users", "", admin)
    |> router.handle(runtime)
  assert listed.status == 200
  let listed_body = response_text(listed)
  assert string.starts_with(listed_body, "[")
  assert string.contains(listed_body, "\"username\":\"pat\"")
  assert string.contains(listed_body, "\"topic\":\"jobs-*\"")
  assert string.contains(listed_body, "\"permission\":\"read-only\"")

  let pat = authorization("pat", "a different secure password")
  let readable =
    api_request(http.Get, "/jobs-nightly/json", "", pat)
    |> request.set_query([#("poll", "1")])
    |> router.handle(runtime)
  assert readable.status == 200
  let forbidden_write =
    api_request(http.Post, "/jobs-nightly", "done", pat)
    |> router.handle(runtime)
  assert forbidden_write.status == 403

  let reset =
    api_request(
      http.Delete,
      "/v1/users/access",
      "{\"username\":\"pat\",\"topic\":\"jobs-*\"}",
      admin,
    )
    |> router.handle(runtime)
  assert reset.status == 200

  let deleted =
    api_request(http.Delete, "/v1/users", "{\"username\":\"pat\"}", admin)
    |> router.handle(runtime)
  assert deleted.status == 200
  let non_admin =
    api_request(
      http.Post,
      "/v1/users",
      "{\"username\":\"nope\",\"password\":\"a sufficiently long password\"}",
      pat,
    )
    |> router.handle(runtime)
  assert non_admin.status == 401
  assert string.contains(response_text(non_admin), "\"code\":40101")
}
