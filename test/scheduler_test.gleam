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
import notify/scheduler
import notify/service
import notify/storage
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
      ids: runtime.IdGenerator(fn() { "Delay00001XY" }),
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
  assert string.contains(response_body(scheduled_poll), "Delay00001XY")

  let deliveries = process.new_subject()
  let due_runtime =
    runtime.Runtime(
      ..first_runtime,
      clock: runtime.Clock(fn() { 1_725_000_600 }),
      broadcast: fn(message) { process.send(deliveries, message) },
    )
  assert service.release_due(due_runtime, 10) == Ok(1)
  let assert Ok(delivered) = process.receive(deliveries, 1000)
  assert delivered.id == "Delay00001XY"

  let after_release = router.handle(poll_request, due_runtime)
  assert string.contains(response_body(after_release), "Delay00001XY")
  assert service.release_due(due_runtime, 10) == Ok(0)
}

pub fn invalid_delay_is_rejected_without_storage_test() {
  let assert Ok(store) = memory.start()
  let runtime =
    runtime.new(
      storage: store,
      clock: runtime.Clock(fn() { 1_725_000_000 }),
      ids: runtime.IdGenerator(fn() { "Delay00002XY" }),
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

pub fn blocked_cleanup_lane_does_not_stop_due_release_or_health_test() {
  let due_calls = process.new_subject()
  let cleanup_started = process.new_subject()
  let health_calls = process.new_subject()
  let persistent =
    storage.Storage(
      migrate: fn() { Ok(Nil) },
      save: fn(message) { Ok(message) },
      query: fn(_) { Ok([]) },
      has_attachment: fn(_, _) { Ok(False) },
      release_due: fn(_, _) {
        process.send(due_calls, Nil)
        Ok([])
      },
      cleanup_expired: fn(_) {
        let blocked = process.new_subject()
        process.send(cleanup_started, Nil)
        let _ = process.receive(blocked, 5000)
        Ok(0)
      },
      stats: fn() { Ok(storage.Stats(0, 0, 0)) },
      health: fn() {
        process.send(health_calls, Nil)
        Ok(Nil)
      },
    )
  let configured =
    runtime.new(
      storage: persistent,
      clock: runtime.Clock(fn() { 1000 }),
      ids: runtime.IdGenerator(fn() { "Schedule01XY" }),
      retention_seconds: 43_200,
    )
  let supervisor = scheduler.start(configured, 10)
  let assert Ok(Nil) = process.receive(cleanup_started, 1000)
  let assert Ok(Nil) = process.receive(due_calls, 1000)
  let assert Ok(Nil) = process.receive(due_calls, 1000)
  let snapshot = runtime.health(configured)
  assert snapshot.storage
  let assert Ok(Nil) = process.receive(health_calls, 1000)
  process.unlink(supervisor)
  process.kill(supervisor)
}
