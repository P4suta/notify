import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import notify/core/message
import notify/core/message_json
import notify/http/router
import notify/runtime
import notify/storage/memory

fn body(response: Response(BitArray)) -> String {
  let assert Ok(value) = bit_array.to_string(response.body)
  value
}

fn test_runtime() -> runtime.Runtime {
  let assert Ok(storage) = memory.start()
  runtime.new(
    storage:,
    clock: runtime.Clock(fn() { 1_725_000_000 }),
    ids: runtime.IdGenerator(fn() { "AbCdEf1234XY" }),
    retention_seconds: 43_200,
  )
}

pub fn plaintext_publish_is_returned_by_json_poll_test() {
  let runtime = test_runtime()
  let publish_request =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/backups")
    |> request.set_body(<<"Backup complete":utf8>>)

  let publish_response = router.handle(publish_request, runtime)
  assert publish_response.status == 200
  let published = body(publish_response)

  let poll_request =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/backups/json")
    |> request.set_query([#("poll", "1")])
    |> request.set_body(<<>>)
  let poll_response = router.handle(poll_request, runtime)

  assert poll_response.status == 200
  assert body(poll_response) == published <> "\n"
  assert response_header(poll_response, "content-type")
    == Ok("application/x-ndjson; charset=utf-8")
}

pub fn json_publish_at_root_uses_ntfy_fields_test() {
  let runtime = test_runtime()
  let publish_request =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/")
    |> request.set_header("content-type", "application/json")
    |> request.set_body(<<
      "{\"topic\":\"alerts\",\"message\":\"Disk full\",\"title\":\"Storage\",\"priority\":5,\"tags\":[\"warning\"]}":utf8,
    >>)
  let response = router.handle(publish_request, runtime)

  assert response.status == 200
  let assert Ok(message) = json.parse(body(response), message_json.decoder())
  assert message.message == "Disk full"
  assert message.title == option.Some("Storage")
  assert message.priority == message.Max
  assert message.tags == ["warning"]
}

pub fn publish_header_aliases_override_plaintext_defaults_test() {
  let runtime = test_runtime()
  let publish_request =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/alerts")
    |> request.set_header("x-title", "Storage")
    |> request.set_header("p", "urgent")
    |> request.set_header("tags", "warning,disk")
    |> request.set_body(<<"Disk full":utf8>>)

  let response = router.handle(publish_request, runtime)
  assert response.status == 200
  let assert Ok(value) = json.parse(body(response), message_json.decoder())
  assert value.title == option.Some("Storage")
  assert value.priority == message.Max
  assert value.tags == ["warning", "disk"]
}

pub fn publish_headers_take_precedence_over_query_aliases_test() {
  let runtime = test_runtime()
  let publish_request =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/alerts")
    |> request.set_query([
      #("title", "query title"),
      #("message", "query message"),
      #("priority", "low"),
    ])
    |> request.set_header("x-title", "header title")
    |> request.set_header("x-message", "header message")
    |> request.set_header("x-priority", "high")
    |> request.set_body(<<"body message":utf8>>)

  let response = router.handle(publish_request, runtime)
  assert response.status == 200
  let assert Ok(value) = json.parse(body(response), message_json.decoder())
  assert value.title == option.Some("header title")
  assert value.message == "body message"
  assert value.priority == message.High
}

pub fn delay_errors_match_the_pinned_ntfy_shape_test() {
  let cases = [
    #("eventually", 40_004, "unable to parse delay"),
    #("9s", 40_005, "too small"),
    #("259201s", 40_006, "too large"),
  ]
  list.each(cases, fn(item) {
    let response =
      request.new()
      |> request.set_method(http.Post)
      |> request.set_path("/alerts")
      |> request.set_header("x-delay", item.0)
      |> request.set_body(<<"later":utf8>>)
      |> router.handle(test_runtime())
    assert response.status == 400
    assert string.contains(body(response), "\"code\":" <> int.to_string(item.1))
    assert string.contains(body(response), item.2)
    assert string.contains(body(response), "#scheduled-delivery")
  })
}

pub fn options_matches_ntfy_cors_contract_test() {
  let response =
    request.new()
    |> request.set_method(http.Options)
    |> request.set_path("/alerts")
    |> request.set_body(<<>>)
    |> router.handle(test_runtime())

  assert response.status == 200
  assert response_header(response, "access-control-allow-origin") == Ok("*")
  assert response_header(response, "access-control-allow-methods")
    == Ok("GET, PUT, POST, PATCH, DELETE")
  assert response_header(response, "access-control-allow-headers") == Ok("*")
}

pub fn invalid_path_topic_is_a_route_miss_like_ntfy_test() {
  let runtime = test_runtime()
  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/bad.topic")
    |> request.set_body(<<"hello":utf8>>)
  let response = router.handle(req, runtime)

  assert response.status == 404
  assert string.contains(body(response), "\"http\":404")
  assert string.contains(body(response), "\"code\":40401")
}

pub fn update_clear_and_delete_are_appended_to_history_test() {
  let runtime = test_runtime()

  let update =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/jobs/nightly-42")
    |> request.set_body(<<"Backup running":utf8>>)
    |> router.handle(runtime)
  assert update.status == 200
  let assert Ok(updated) = json.parse(body(update), message_json.decoder())
  assert updated.event == message.MessageEvent
  assert updated.sequence_id == option.Some("nightly-42")

  let clear =
    request.new()
    |> request.set_method(http.Put)
    |> request.set_path("/jobs/nightly-42/clear")
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert clear.status == 200
  let assert Ok(cleared) = json.parse(body(clear), message_json.decoder())
  assert cleared.event == message.MessageClearEvent
  assert cleared.sequence_id == option.Some("nightly-42")
  assert !string.contains(body(clear), "\"message\"")
  assert !string.contains(body(clear), "\"expires\"")

  let delete =
    request.new()
    |> request.set_method(http.Delete)
    |> request.set_path("/jobs/nightly-42")
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert delete.status == 200
  let assert Ok(deleted) = json.parse(body(delete), message_json.decoder())
  assert deleted.event == message.MessageDeleteEvent
  assert deleted.sequence_id == option.Some("nightly-42")
  assert !string.contains(body(delete), "\"message\"")
  assert !string.contains(body(delete), "\"expires\"")

  let poll =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/jobs/json")
    |> request.set_query([#("poll", "1")])
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert poll.status == 200
  assert poll.body
    |> bit_array.to_string
    |> result.unwrap("")
    |> string.split("\n")
    |> list.filter(fn(line) { !string.is_empty(line) })
    |> list.length
    == 3
}

pub fn sequence_id_short_alias_is_supported_test() {
  let runtime = test_runtime()
  let response =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/jobs")
    |> request.set_header("sid", "nightly-43")
    |> request.set_body(<<"Backup running":utf8>>)
    |> router.handle(runtime)

  assert response.status == 200
  let assert Ok(value) = json.parse(body(response), message_json.decoder())
  assert value.sequence_id == option.Some("nightly-43")
}

pub fn invalid_sequence_parameter_uses_ntfy_40049_error_test() {
  let runtime = test_runtime()
  let too_long =
    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

  let header_response =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/jobs")
    |> request.set_header("x-sequence-id", too_long)
    |> request.set_body(<<"Backup running":utf8>>)
    |> router.handle(runtime)
  assert header_response.status == 400
  assert string.contains(body(header_response), "\"code\":40049")
  assert string.contains(
    body(header_response),
    "invalid request: sequence ID invalid",
  )

  let query_response =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/jobs")
    |> request.set_query([#("sequence-id", "invalid*sequence")])
    |> request.set_body(<<"Backup running":utf8>>)
    |> router.handle(runtime)
  assert query_response.status == 400
  assert string.contains(body(query_response), "\"code\":40049")

  let json_response =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/")
    |> request.set_header("content-type", "application/json")
    |> request.set_body(<<
      "{\"topic\":\"jobs\",\"message\":\"Backup running\",\"sequence_id\":\"invalid*sequence\"}":utf8,
    >>)
    |> router.handle(runtime)
  assert json_response.status == 400
  assert string.contains(body(json_response), "\"code\":40049")
}

pub fn invalid_sequence_path_is_a_route_miss_like_ntfy_test() {
  let runtime = test_runtime()
  let too_long =
    "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"

  let delete_response =
    request.new()
    |> request.set_method(http.Delete)
    |> request.set_path("/jobs/" <> too_long)
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert delete_response.status == 404
  assert string.contains(body(delete_response), "\"code\":40401")

  let update_response =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/jobs/invalid*sequence")
    |> request.set_body(<<"Backup running":utf8>>)
    |> router.handle(runtime)
  assert update_response.status == 404
  assert string.contains(body(update_response), "\"code\":40401")

  let clear_response =
    request.new()
    |> request.set_method(http.Put)
    |> request.set_path("/jobs/invalid*sequence/clear")
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert clear_response.status == 404
  assert string.contains(body(clear_response), "\"code\":40401")
}

pub fn cache_disabled_message_is_committed_but_not_returned_by_poll_test() {
  let runtime = test_runtime()
  let publish =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/ephemeral")
    |> request.set_header("cache", "no")
    |> request.set_body(<<"live only":utf8>>)
    |> router.handle(runtime)
  assert publish.status == 200

  let poll =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/ephemeral/json")
    |> request.set_query([#("poll", "1")])
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert poll.status == 200
  assert body(poll) == ""
  assert runtime.storage.cleanup_expired(1_725_000_000) == Ok(1)
}

pub fn invalid_header_priority_is_rejected_without_persisting_test() {
  let runtime = test_runtime()
  let publish =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/alerts")
    |> request.set_header("priority", "impossible")
    |> request.set_body(<<"must not persist":utf8>>)
    |> router.handle(runtime)
  assert publish.status == 400
  assert string.contains(body(publish), "\"code\":40007")

  let poll =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/alerts/json")
    |> request.set_query([#("poll", "1")])
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert body(poll) == ""
}

pub fn rfc_9218_priority_header_is_ignored_like_ntfy_v2_27_test() {
  let runtime = test_runtime()
  let publish =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/alerts")
    |> request.set_query([#("priority", "high")])
    |> request.set_header("priority", "u=4, i")
    |> request.set_body(<<"browser request":utf8>>)
    |> router.handle(runtime)
  assert publish.status == 200
  let assert Ok(value) = json.parse(body(publish), message_json.decoder())
  assert value.priority == message.High

  let poll =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/alerts/json")
    |> request.set_query([#("poll", "1")])
    |> request.set_header("priority", "u=9")
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert poll.status == 200
  assert string.contains(body(poll), "browser request")
}

pub fn rfc_9218_shape_is_only_ignored_for_plain_priority_header_test() {
  let runtime = test_runtime()
  let query =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/alerts/json")
    |> request.set_query([#("poll", "1"), #("priority", "u=4")])
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert query.status == 400

  let x_priority =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/alerts/json")
    |> request.set_query([#("poll", "1")])
    |> request.set_header("x-priority", "u=4")
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert x_priority.status == 400
}

pub fn delayed_message_cannot_disable_cache_test() {
  let runtime = test_runtime()
  let publish =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/alerts")
    |> request.set_header("delay", "10m")
    |> request.set_header("cache", "no")
    |> request.set_body(<<"later":utf8>>)
    |> router.handle(runtime)
  assert publish.status == 400
  assert string.contains(body(publish), "\"code\":40002")
}

pub fn raw_poll_flattens_embedded_newlines_and_priority_filter_accepts_csv_test() {
  let runtime = test_runtime()
  let _ =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/alerts")
    |> request.set_header("priority", "max")
    |> request.set_body(<<"first\nsecond\r\nthird":utf8>>)
    |> router.handle(runtime)

  let poll =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/alerts/raw")
    |> request.set_query([#("poll", "1"), #("priority", "min,max")])
    |> request.set_body(<<>>)
    |> router.handle(runtime)
  assert poll.status == 200
  assert body(poll) == "first second  third\n"
}

pub fn action_header_supports_ntfy_simple_format_test() {
  let response =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/alerts")
    |> request.set_header(
      "actions",
      "view, Open, https://example.test, clear=true; copy, Copy OTP, 123456",
    )
    |> request.set_body(<<"Act now":utf8>>)
    |> router.handle(test_runtime())
  assert response.status == 200
  let assert Ok(value) = json.parse(body(response), message_json.decoder())
  assert value.actions
    == [
      message.ViewAction(
        label: "Open",
        url: "https://example.test",
        clear: True,
        id: option.Some("AbCdEf12AA"),
      ),
      message.CopyAction(
        label: "Copy OTP",
        value: "123456",
        clear: False,
        id: option.Some("AbCdEf12AB"),
      ),
    ]
}

pub fn invalid_action_header_uses_ntfy_error_code_test() {
  let response =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/alerts")
    |> request.set_header("actions", "copy, Missing value")
    |> request.set_body(<<"Act now":utf8>>)
    |> router.handle(test_runtime())
  assert response.status == 400
  assert string.contains(body(response), "\"code\":40018")
}

fn response_header(
  response: Response(BitArray),
  name: String,
) -> Result(String, Nil) {
  response.headers
  |> list.find_map(fn(pair) {
    case pair.0 == name {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
}
