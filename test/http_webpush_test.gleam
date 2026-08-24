import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/string
import notify/http/router
import notify/runtime
import notify/storage/memory as storage_memory
import notify/webpush
import notify/webpush/memory as webpush_memory

fn webpush_runtime() -> #(runtime.Runtime, webpush.Store) {
  let assert Ok(messages) = storage_memory.start()
  let assert Ok(subscriptions) = webpush_memory.start(max_endpoints_per_ip: 10)
  let configured =
    runtime.WebPushRuntime(
      store: subscriptions,
      public_key: "BDummyPublicVapidKey",
      private_key: "dummy-private-key",
      subscriber: "admin@example.test",
    )
  #(
    runtime.new(
      storage: messages,
      clock: runtime.Clock(fn() { 1000 }),
      ids: runtime.IdGenerator(fn() { "WebPush001" }),
      retention_seconds: 43_200,
    )
      |> runtime.with_webpush(configured),
    subscriptions,
  )
}

fn call(method: http.Method, body: String, runtime: runtime.Runtime) {
  request.new()
  |> request.set_method(method)
  |> request.set_path("/v1/webpush")
  |> request.set_body(bit_array.from_string(body))
  |> router.handle(runtime)
}

pub fn webpush_compatibility_api_upserts_and_deletes_subscription_test() {
  let #(runtime, subscriptions) = webpush_runtime()
  let endpoint =
    "https://updates.push.services.mozilla.com/wpush/v2/browser-token"
  let response =
    call(
      http.Post,
      "{\"endpoint\":\""
        <> endpoint
        <> "\",\"auth\":\"kSC3T8aN1JCQxxPdrFLrZg\",\"p256dh\":\"BMKKbxdUU_xLS7G1Wh5AN8PvWOjCzkCuKZYb8apcqYrDxjOF_2piggBnoJLQYx9IeSD70fNuwawI3e9Y8m3S3PE\",\"topics\":[\"alerts\"]}",
      runtime,
    )
  assert response.status == 200
  assert bit_array.to_string(response.body) == Ok("{\"success\":true}")
  let assert Ok([saved]) = subscriptions.for_topic("alerts")
  assert saved.endpoint == endpoint

  let removed =
    call(http.Delete, "{\"endpoint\":\"" <> endpoint <> "\"}", runtime)
  assert removed.status == 200
  assert subscriptions.for_topic("alerts") == Ok([])
}

pub fn webpush_api_rejects_unknown_endpoint_and_reports_public_config_test() {
  let #(runtime, _) = webpush_runtime()
  let invalid =
    call(
      http.Post,
      "{\"endpoint\":\"https://attacker.test/fcm.googleapis.com/token\",\"auth\":\"YXV0aA\",\"p256dh\":\"a2V5\",\"topics\":[\"alerts\"]}",
      runtime,
    )
  assert invalid.status == 400
  let assert Ok(invalid_body) = bit_array.to_string(invalid.body)
  assert string.contains(invalid_body, "\"code\":40039")
  assert !string.contains(invalid_body, "\"link\"")

  let config_response =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/v1/config")
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  let assert Ok(config_body) = bit_array.to_string(config_response.body)
  assert string.contains(config_body, "\"enable_web_push\":true")
  assert string.contains(config_body, "BDummyPublicVapidKey")
  assert !string.contains(config_body, "dummy-private-key")
}

pub fn webpush_api_is_not_exposed_when_unconfigured_test() {
  let assert Ok(messages) = storage_memory.start()
  let runtime =
    runtime.new(
      storage: messages,
      clock: runtime.Clock(fn() { 1000 }),
      ids: runtime.IdGenerator(fn() { "WebPush001" }),
      retention_seconds: 43_200,
    )
  let response = call(http.Post, "{}", runtime)
  assert response.status == 404

  let config_response =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/v1/config")
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  let assert Ok(config_body) = bit_array.to_string(config_response.body)
  assert string.contains(config_body, "\"enable_login\":false")
  assert string.contains(config_body, "\"require_login\":false")
}

pub fn pwa_exposes_webpush_registration_and_notification_handlers_test() {
  let #(runtime, _) = webpush_runtime()
  let asset = fn(path) {
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path(path)
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  }
  let assert Ok(index) = bit_array.to_string(asset("/").body)
  let assert Ok(app) = bit_array.to_string(asset("/notify_web.js").body)
  let assert Ok(worker) = bit_array.to_string(asset("/sw.js").body)
  assert string.contains(index, "id=\"app\"")
  assert string.contains(index, "src=\"/notify_web.js\"")
  assert string.contains(app, "pushManager.subscribe")
  assert string.contains(app, "/v1/webpush")
  assert string.contains(worker, "addEventListener('push'")
  assert string.contains(worker, "addEventListener('notificationclick'")
}
