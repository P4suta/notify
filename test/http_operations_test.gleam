import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/string
import notify/http/router
import notify/runtime
import notify/storage
import notify/storage/memory

fn call(path: String, runtime: runtime.Runtime) {
  request.new()
  |> request.set_method(http.Get)
  |> request.set_path(path)
  |> request.set_body(<<>>)
  |> router.handle(runtime)
}

pub fn liveness_readiness_and_prometheus_endpoints_are_distinct_test() {
  let assert Ok(messages) = memory.start()
  let runtime =
    runtime.new(
      storage: messages,
      clock: runtime.Clock(fn() { 1000 }),
      ids: runtime.IdGenerator(fn() { "OpsMetric1" }),
      retention_seconds: 43_200,
    )

  let live = call("/healthz", runtime)
  assert live.status == 200
  assert bit_array.to_string(live.body) == Ok("ok\n")
  let assert Ok(generated_request_id) =
    response.get_header(live, "x-request-id")
  assert string.length(generated_request_id) == 10
  let ready = call("/readyz", runtime)
  assert ready.status == 200
  assert bit_array.to_string(ready.body) == Ok("ready\n")

  let metrics = call("/metrics", runtime)
  assert metrics.status == 200
  let assert Ok(content_type) = response.get_header(metrics, "content-type")
  assert string.contains(content_type, "text/plain")
  let assert Ok(body) = bit_array.to_string(metrics.body)
  assert string.contains(body, "notify_up 1")
  assert string.contains(body, "notify_messages 0")
  assert string.contains(body, "notify_scheduled_messages 0")
  assert string.contains(body, "notify_event_log_entries 0")
}

pub fn safe_request_id_is_preserved_and_header_injection_is_rejected_test() {
  let assert Ok(messages) = memory.start()
  let runtime =
    runtime.new(
      storage: messages,
      clock: runtime.Clock(fn() { 1000 }),
      ids: runtime.IdGenerator(fn() { "OpsMetric1" }),
      retention_seconds: 43_200,
    )
  let accepted =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/healthz")
    |> request.set_header("x-request-id", "edge_01.trace-9")
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert response.get_header(accepted, "x-request-id") == Ok("edge_01.trace-9")

  let rejected =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/healthz")
    |> request.set_header("x-request-id", "unsafe/id")
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  let assert Ok(replacement) = response.get_header(rejected, "x-request-id")
  assert replacement != "unsafe/id"
  assert string.length(replacement) == 10
}

pub fn readiness_fails_but_liveness_survives_dependency_failure_test() {
  let unavailable =
    storage.Storage(
      migrate: fn() { Ok(Nil) },
      save: fn(message) { Ok(message) },
      query: fn(_) { Ok([]) },
      release_due: fn(_, _) { Ok([]) },
      cleanup_expired: fn(_) { Ok(0) },
      stats: fn() { Error(storage.Unavailable("offline")) },
      health: fn() { Error(storage.Unavailable("offline")) },
    )
  let runtime =
    runtime.new(
      storage: unavailable,
      clock: runtime.Clock(fn() { 1000 }),
      ids: runtime.IdGenerator(fn() { "OpsMetric1" }),
      retention_seconds: 43_200,
    )
  assert call("/healthz", runtime).status == 200
  assert call("/readyz", runtime).status == 503
  let metrics = call("/metrics", runtime)
  let assert Ok(body) = bit_array.to_string(metrics.body)
  assert string.contains(body, "notify_up 0")
}
