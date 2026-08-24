import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response.{type Response}
import gleam/json
import gleam/string
import notify/core/message_json
import notify/http/router
import notify/runtime
import notify/service
import notify/storage/memory

fn response_body(response: Response(BitArray)) -> String {
  let assert Ok(value) = bit_array.to_string(response.body)
  value
}

pub fn delayed_message_is_hidden_until_atomically_released_test() {
  let assert Ok(store) = memory.start()
  let first_runtime =
    runtime.new(
      storage: store,
      clock: runtime.Clock(fn() { 1_725_000_000 }),
      ids: runtime.IdGenerator(fn() { "Delay00001" }),
      retention_seconds: 43_200,
    )
  let publish =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/backups")
    |> request.set_header("delay", "10m")
    |> request.set_body(<<"Backup complete":utf8>>)
    |> router.handle(first_runtime)
  assert publish.status == 200
  let assert Ok(scheduled) =
    json.parse(response_body(publish), message_json.decoder())
  assert scheduled.time == 1_725_000_600

  let poll_request =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/backups/json")
    |> request.set_query([#("poll", "1")])
    |> request.set_body(<<>>)
  let normal_poll = router.handle(poll_request, first_runtime)
  assert response_body(normal_poll) == ""

  let scheduled_poll =
    request.new()
    |> request.set_method(http.Get)
    |> request.set_path("/backups/json")
    |> request.set_query([#("poll", "1"), #("scheduled", "1")])
    |> request.set_body(<<>>)
    |> router.handle(first_runtime)
  assert string.contains(response_body(scheduled_poll), "Delay00001")

  let deliveries = process.new_subject()
  let due_runtime =
    runtime.Runtime(
      ..first_runtime,
      clock: runtime.Clock(fn() { 1_725_000_600 }),
      broadcast: fn(message) { process.send(deliveries, message) },
    )
  assert service.release_due(due_runtime, 10) == Ok(1)
  let assert Ok(delivered) = process.receive(deliveries, 1000)
  assert delivered.id == "Delay00001"

  let after_release = router.handle(poll_request, due_runtime)
  assert string.contains(response_body(after_release), "Delay00001")
  assert service.release_due(due_runtime, 10) == Ok(0)
}

pub fn invalid_delay_is_rejected_without_storage_test() {
  let assert Ok(store) = memory.start()
  let runtime =
    runtime.new(
      storage: store,
      clock: runtime.Clock(fn() { 1_725_000_000 }),
      ids: runtime.IdGenerator(fn() { "Delay00002" }),
      retention_seconds: 43_200,
    )
  let publish =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/backups")
    |> request.set_header("delay", "yesterday")
    |> request.set_body(<<"Backup complete":utf8>>)
    |> router.handle(runtime)
  assert publish.status == 400
}
