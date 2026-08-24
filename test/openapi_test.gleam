import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/json
import gleam/list
import gleam/string
import notify/http/live
import notify/http/router
import notify/runtime
import notify/storage/memory
import notify/webpush/memory as webpush_memory

type Operation {
  Operation(path: String, method: String, operation_id: String)
}

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
  assert string.contains(body, "/api/v1/audit")
  assert string.contains(body, "AuditEvent")
  assert string.contains(
    body,
    "Opaque, resource-scoped base64url keyset cursor returned by the preceding audit page",
  )
  assert string.contains(body, "/file/{topic}/{key}/{filename}")
  assert string.contains(body, "AttachmentRange")
  assert string.contains(body, "RateLimited")
  assert string.contains(body, "RateLimit-Remaining")
  assert string.contains(body, "X-Notify-RateLimit-Bucket")
  assert string.contains(body, "^[A-Za-z0-9]{12}$")
  assert string.contains(body, "/api/v1/anonymous-access")
  assert string.contains(body, "X-Template")
  assert string.contains(body, "bounded inline templates")
}

pub fn every_openapi_operation_has_stable_complete_metadata_test() {
  let operations = documented_operations(openapi_body())

  assert list.length(operations) == 68
  let operation_ids =
    list.map(operations, fn(operation) { operation.operation_id })
  assert list.length(list.unique(operation_ids)) == list.length(operation_ids)
}

pub fn every_openapi_operation_is_bound_to_a_runtime_route_test() {
  let assert Ok(store) = memory.start()
  let assert Ok(push_store) = webpush_memory.start(10)
  let runtime =
    runtime.new(
      storage: store,
      clock: runtime.Clock(fn() { 1000 }),
      ids: runtime.secure_ids(),
      retention_seconds: 43_200,
    )
    |> runtime.with_webpush(runtime.WebPushRuntime(
      store: push_store,
      public_key: "openapi-test-public-key",
      private_key: "openapi-test-private-key",
      subscriber: "mailto:openapi@example.com",
    ))
  let unbound =
    openapi_body()
    |> documented_operations
    |> list.filter_map(fn(operation) {
      case operation.path {
        "/{topics}/ws" ->
          case live.matches(operation_request(operation)) {
            True -> Error(Nil)
            False -> Ok(operation.method <> " " <> operation.path)
          }
        _ -> {
          let response =
            operation |> operation_request |> router.handle(runtime)
          case is_page_not_found(response.status, response.body) {
            True -> Ok(operation.method <> " " <> operation.path)
            False -> Error(Nil)
          }
        }
      }
    })

  assert unbound == []
}

pub fn management_collection_openapi_contracts_are_keyset_paginated_test() {
  let body = openapi_body()
  let assert Ok(paths) =
    json.parse(body, {
      use paths <- decode.field(
        "paths",
        decode.dict(decode.string, decode.dict(decode.string, decode.dynamic)),
      )
      decode.success(paths)
    })
  list.each(
    [
      #("/api/v1/users", "UserPage"),
      #("/api/v1/tokens", "TokenPage"),
      #("/api/v1/acl", "AclPage"),
      #("/api/v1/delivery-jobs", "DeliveryJobPage"),
      #("/api/v1/attachments", "AttachmentPage"),
    ],
    fn(contract) {
      let #(path, page_schema) = contract
      let assert Ok(path_item) = dict.get(paths, path)
      let assert Ok(document) = dict.get(path_item, "get")
      let assert Ok(parameters) =
        decode.run(document, {
          use parameters <- decode.field(
            "parameters",
            decode.list(decode.dynamic),
          )
          decode.success(parameters)
        })
      let references =
        list.filter_map(parameters, fn(parameter) {
          decode.run(parameter, {
            use reference <- decode.field("$ref", decode.string)
            decode.success(reference)
          })
        })
      assert list.contains(references, "#/components/parameters/cursor")
      assert list.contains(references, "#/components/parameters/limit")
      let assert Ok(response_schema) =
        decode.run(
          document,
          decode.at(
            [
              "responses",
              "200",
              "content",
              "application/json",
              "schema",
              "$ref",
            ],
            decode.string,
          ),
        )
      assert response_schema == "#/components/schemas/" <> page_schema
    },
  )
  assert string.contains(body, "resource-scoped base64url keyset cursor")
  assert string.contains(body, "bound to the collection and active filters")
}

fn documented_operations(body: String) -> List(Operation) {
  let assert Ok(paths) =
    json.parse(body, {
      use paths <- decode.field(
        "paths",
        decode.dict(decode.string, decode.dict(decode.string, decode.dynamic)),
      )
      decode.success(paths)
    })
  let operations =
    paths
    |> dict.to_list
    |> list.flat_map(fn(path_entry) {
      let #(path, methods) = path_entry
      methods
      |> dict.to_list
      |> list.filter(fn(method_entry) {
        let #(method, _) = method_entry
        is_operation_method(method)
      })
      |> list.map(fn(method_entry) {
        let #(method, document) = method_entry
        let assert Ok(#(operation_id, tags, responses)) =
          decode.run(document, {
            use operation_id <- decode.field("operationId", decode.string)
            use tags <- decode.field("tags", decode.list(decode.string))
            use responses <- decode.field(
              "responses",
              decode.dict(decode.string, decode.dynamic),
            )
            decode.success(#(operation_id, tags, responses))
          })
        assert tags != []
        assert dict.size(responses) > 0
        Operation(path:, method:, operation_id:)
      })
    })
  operations
}

fn openapi_body() -> String {
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
  body
}

fn is_operation_method(method: String) -> Bool {
  list.contains(["get", "post", "put", "patch", "delete", "head"], method)
}

fn operation_request(operation: Operation) -> request.Request(BitArray) {
  let assert Ok(method) = http.parse_method(string.uppercase(operation.method))
  let path = materialise_path(operation.path, operation.method)
  let req =
    request.new()
    |> request.set_method(method)
    |> request.set_path(path)
    |> request.set_body(bit_array.from_string("{}"))
  case
    string.ends_with(path, "/json")
    || string.ends_with(path, "/sse")
    || string.ends_with(path, "/raw")
  {
    True -> request.set_query(req, [#("poll", "1")])
    False -> req
  }
}

fn materialise_path(path: String, method: String) -> String {
  path
  |> string.replace("{topic}", "openapi")
  |> string.replace("{topics}", "openapi")
  |> string.replace("{key}", string.repeat("0", 64))
  |> string.replace("{filename}", "fixture.txt")
  |> string.replace("{username}", "openapi-user")
  |> string.replace("{id}", "missing-id")
  |> string.replace("{sequence_id}", "sequence-1")
  |> string.replace("{clear_action}", "clear")
  |> string.replace("{message_or_action}", case method {
    "get" -> "trigger"
    _ -> "sequence-1"
  })
}

fn is_page_not_found(status: Int, body: BitArray) -> Bool {
  case bit_array.to_string(body) {
    Ok(body) -> status == 404 && string.contains(body, "\"page not found\"")
    Error(_) -> False
  }
}
