import gleam/bit_array
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/option.{None, Some}
import gleam/string
import notify/access
import notify/audit
import notify/audit/memory as audit_memory
import notify/http/router
import notify/identity/sqlite as identity_sqlite
import notify/runtime
import notify/storage/memory as storage_memory

const setup_entropy = "abcdefghijklmnopqrstuvwxyz123"

const setup_token = "su_abcdefghijklmnopqrstuvwxyz123"

const admin_password = "audit admin password secret"

fn managed_runtime() -> runtime.Runtime {
  let assert Ok(identity_sqlite.Started(identity, Some(raw_setup_token))) =
    identity_sqlite.start(":memory:", fn() { 1000 }, fn() { setup_entropy })
  assert raw_setup_token == setup_token
  let assert Ok(control) = access.managed(identity)
  let assert Ok(messages) = storage_memory.start()
  let assert Ok(audits) = audit_memory.start()
  runtime.new(
    storage: messages,
    clock: runtime.Clock(fn() { 1001 }),
    ids: runtime.secure_ids(),
    retention_seconds: 43_200,
  )
  |> runtime.with_access(control)
  |> runtime.with_audit(audits)
}

fn internal_request(method: http.Method, path: String, body: String) {
  request.new()
  |> request.set_method(method)
  |> request.set_path(path)
  |> request.set_header("x-request-id", "audit-request-1")
  |> request.set_header("x-notify-client-ip", "203.0.113.9")
  |> request.set_body(bit_array.from_string(body))
}

fn admin_header() -> String {
  let credentials = "admin:" <> admin_password
  credentials
  |> bit_array.from_string
  |> bit_array.base64_encode(True)
  |> fn(value) { "Basic " <> value }
}

fn admin_request(method: http.Method, path: String, body: String) {
  internal_request(method, path, body)
  |> request.set_header("authorization", admin_header())
}

pub fn security_and_admin_events_are_durable_redacted_and_paginated_test() {
  let runtime = managed_runtime()
  let setup =
    internal_request(
      http.Post,
      "/api/v1/setup",
      "{\"token\":\""
        <> setup_token
        <> "\",\"username\":\"admin\",\"password\":\""
        <> admin_password
        <> "\",\"anonymous_access\":\"deny\"}",
    )
    |> router.handle(runtime)
  assert setup.status == 201

  let denied_login =
    internal_request(
      http.Post,
      "/api/v1/session",
      "{\"username\":\"admin\",\"password\":\"wrong login secret\"}",
    )
    |> router.handle(runtime)
  assert denied_login.status == 401

  let created =
    admin_request(
      http.Post,
      "/api/v1/users",
      "{\"username\":\"pat\",\"password\":\"new user password secret\",\"role\":\"user\"}",
    )
    |> router.handle(runtime)
  assert created.status == 201

  let unauthorized =
    internal_request(http.Get, "/api/v1/audit", "")
    |> router.handle(runtime)
  assert unauthorized.status == 401

  let all_events =
    admin_request(http.Get, "/api/v1/audit", "")
    |> request.set_query([#("limit", "100")])
    |> router.handle(runtime)
  assert all_events.status == 200
  let assert Ok(all_body) = bit_array.to_string(all_events.body)
  assert string.contains(all_body, "\"action\":\"setup.complete\"")
  assert string.contains(all_body, "\"action\":\"session.login\"")
  assert string.contains(all_body, "\"action\":\"user.create\"")
  assert string.contains(all_body, "\"outcome\":\"attempted\"")
  assert string.contains(all_body, "\"outcome\":\"succeeded\"")
  assert string.contains(all_body, "\"outcome\":\"denied\"")
  assert !string.contains(all_body, setup_token)
  assert !string.contains(all_body, admin_password)
  assert !string.contains(all_body, "wrong login secret")
  assert !string.contains(all_body, "new user password secret")
  assert !string.contains(all_body, admin_header())

  let first_page =
    admin_request(http.Get, "/api/v1/audit", "")
    |> request.set_query([#("limit", "2")])
    |> router.handle(runtime)
  let assert Ok(first_body) = bit_array.to_string(first_page.body)
  let assert Ok(next_cursor) =
    json.parse(first_body, {
      use cursor <- decode.field("next_cursor", decode.string)
      decode.success(cursor)
    })
  assert !string.contains(next_cursor, ":")
  let second_page =
    admin_request(http.Get, "/api/v1/audit", "")
    |> request.set_query([#("limit", "2"), #("cursor", next_cursor)])
    |> router.handle(runtime)
  assert second_page.status == 200

  let invalid =
    admin_request(http.Get, "/api/v1/audit", "")
    |> request.set_query([#("cursor", "not+base64")])
    |> router.handle(runtime)
  assert invalid.status == 400
  let invalid_limit =
    admin_request(http.Get, "/api/v1/audit", "")
    |> request.set_query([#("limit", "101")])
    |> router.handle(runtime)
  assert invalid_limit.status == 400
}

pub fn mutation_is_not_run_when_the_audit_attempt_cannot_be_persisted_test() {
  let runtime = managed_runtime()
  let setup =
    internal_request(
      http.Post,
      "/api/v1/setup",
      "{\"token\":\""
        <> setup_token
        <> "\",\"username\":\"admin\",\"password\":\""
        <> admin_password
        <> "\",\"anonymous_access\":\"deny\"}",
    )
    |> router.handle(runtime)
  assert setup.status == 201

  let unavailable = audit.Unavailable("injected audit outage")
  let failing_store =
    audit.Store(
      append: fn(_) { Error(unavailable) },
      page: fn(_, _) { Error(unavailable) },
      health: fn() { Error(unavailable) },
    )
  let blocked_runtime = runtime.Runtime(..runtime, audit: Some(failing_store))
  let blocked =
    admin_request(
      http.Post,
      "/api/v1/users",
      "{\"username\":\"blocked\",\"password\":\"must never be stored\",\"role\":\"user\"}",
    )
    |> router.handle(blocked_runtime)
  assert blocked.status == 503

  let listed =
    admin_request(http.Get, "/api/v1/users", "")
    |> router.handle(runtime)
  let assert Ok(body) = bit_array.to_string(listed.body)
  assert !string.contains(body, "blocked")
  assert !string.contains(body, "must never be stored")
}

pub fn successful_mutation_reports_an_incomplete_result_event_test() {
  let runtime = managed_runtime()
  let setup =
    internal_request(
      http.Post,
      "/api/v1/setup",
      "{\"token\":\""
        <> setup_token
        <> "\",\"username\":\"admin\",\"password\":\""
        <> admin_password
        <> "\",\"anonymous_access\":\"deny\"}",
    )
    |> router.handle(runtime)
  assert setup.status == 201

  let assert Some(durable_store) = runtime.audit
  let append_results = process.new_subject()
  process.send(append_results, True)
  process.send(append_results, False)
  let unavailable = audit.Unavailable("injected audit result outage")
  let flaky_store =
    audit.Store(
      append: fn(event) {
        let assert Ok(allowed) = process.receive(append_results, 1000)
        case allowed {
          True -> durable_store.append(event)
          False -> Error(unavailable)
        }
      },
      page: durable_store.page,
      health: durable_store.health,
    )
  let flaky_runtime = runtime.Runtime(..runtime, audit: Some(flaky_store))
  let created =
    admin_request(
      http.Post,
      "/api/v1/users",
      "{\"username\":\"created\",\"password\":\"result failure secret\",\"role\":\"user\"}",
    )
    |> router.handle(flaky_runtime)
  assert created.status == 201
  assert response.get_header(created, "x-notify-audit-status")
    == Ok("incomplete")

  let assert Ok(audit.Page([latest, ..], _)) = durable_store.page(None, 100)
  assert latest.action == audit.UserCreate
  assert latest.outcome == audit.Attempted
  let listed =
    admin_request(http.Get, "/api/v1/users", "")
    |> router.handle(runtime)
  let assert Ok(body) = bit_array.to_string(listed.body)
  assert string.contains(body, "created")
  assert !string.contains(body, "result failure secret")
}
