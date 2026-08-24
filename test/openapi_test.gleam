import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/json
import gleam/string
import notify/http/router
import notify/runtime
import notify/storage/memory

pub fn openapi_document_is_valid_json_and_describes_security_boundaries_test() {
  let assert Ok(store) = memory.start()
  let runtime =
    runtime.new(
      storage: store,
      clock: runtime.Clock(fn() { 1000 }),
      ids: runtime.IdGenerator(fn() { "OpenApi001XY" }),
      retention_seconds: 43_200,
    )
  let response =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/api/openapi.json")
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert response.status == 200
  let assert Ok(body) = bit_array.to_string(response.body)
  let assert Ok(version) =
    json.parse(body, {
      use version <- decode.field("openapi", decode.string)
      decode.success(version)
    })
  assert version == "3.1.0"
  assert string.contains(body, "notify_session")
  assert string.contains(body, "X-CSRF-Token")
  assert string.contains(body, "/{topics}/ws")
  assert string.contains(body, "/v1/webpush")
  assert string.contains(body, "/v1/account/token")
  assert string.contains(body, "/v1/users/access")
  assert string.contains(body, "/healthz")
  assert string.contains(body, "/readyz")
  assert string.contains(body, "/metrics")
  assert string.contains(body, "/api/v1/delivery-jobs")
  assert string.contains(body, "/api/v1/delivery-jobs/{id}/retry")
  assert string.contains(body, "/api/v1/attachments/{key}")
  assert string.contains(body, "/api/v1/anonymous-access")
}
