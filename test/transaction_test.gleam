import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/list
import gleam/option.{None}
import gleam/string
import notify/attachment_store/filesystem
import notify/core/filter
import notify/core/message
import notify/core/topic
import notify/delivery
import notify/delivery/sqlite as delivery_sqlite
import notify/http/router
import notify/runtime
import notify/service
import notify/storage
import notify/storage/sqlite

pub fn storage_failure_returns_503_and_does_not_fan_out_test() {
  let storage =
    storage.Storage(
      migrate: fn() { Ok(Nil) },
      save: fn(_) { Error(storage.Unavailable("database offline")) },
      query: fn(_) { Ok([]) },
      has_attachment: fn(_, _) { Ok(False) },
      release_due: fn(_, _) { Ok([]) },
      cleanup_expired: fn(_) { Ok(0) },
      stats: fn() { Ok(storage.Stats(0, 0, 0)) },
      health: fn() { Error(storage.Unavailable("database offline")) },
    )
  let runtime =
    runtime.new(
      storage:,
      clock: runtime.Clock(fn() { 1_725_000_000 }),
      ids: runtime.IdGenerator(fn() { "AbCdEf1234XY" }),
      retention_seconds: 43_200,
    )
    |> runtime.with_broadcast(fn(_) { panic as "must not fan out" })

  let req =
    request.new()
    |> request.set_method(http.Post)
    |> request.set_path("/backups")
    |> request.set_body(<<"Backup complete":utf8>>)
  let response = router.handle(req, runtime)
  let assert Ok(body) = bit_array.to_string(response.body)

  assert response.status == 503
  assert string.contains(body, "temporarily unavailable")
}

pub fn message_id_conflicts_are_retried_before_fanout_test() {
  let ids = process.new_subject()
  process.send(ids, "Collision001")
  process.send(ids, "Recovered001")
  let broadcasts = process.new_subject()
  let persistent =
    storage.Storage(
      migrate: fn() { Ok(Nil) },
      save: fn(message) {
        case message.id {
          "Collision001" -> Error(storage.Conflict("duplicate message ID"))
          _ -> Ok(message)
        }
      },
      query: fn(_) { Ok([]) },
      has_attachment: fn(_, _) { Ok(False) },
      release_due: fn(_, _) { Ok([]) },
      cleanup_expired: fn(_) { Ok(0) },
      stats: fn() { Ok(storage.Stats(0, 0, 0)) },
      health: fn() { Ok(Nil) },
    )
  let configured =
    runtime.new(
      storage: persistent,
      clock: runtime.Clock(fn() { 100 }),
      ids: runtime.IdGenerator(fn() {
        process.receive(ids, 1000) |> result_unwrap("missing test ID")
      }),
      retention_seconds: 43_200,
    )
    |> runtime.with_broadcast(fn(message) { process.send(broadcasts, message) })
  let assert Ok(alerts) = topic.parse("alerts")

  let assert Ok(saved) =
    service.publish(message.plaintext_draft(alerts, "hello"), configured)
  assert saved.id == "Recovered001"
  assert process.receive(broadcasts, 1000) == Ok(saved)
  assert process.receive(broadcasts, 10) == Error(Nil)
}

pub fn message_id_conflict_retry_is_bounded_test() {
  let persistent =
    storage.Storage(
      migrate: fn() { Ok(Nil) },
      save: fn(_) { Error(storage.Conflict("duplicate message ID")) },
      query: fn(_) { Ok([]) },
      has_attachment: fn(_, _) { Ok(False) },
      release_due: fn(_, _) { Ok([]) },
      cleanup_expired: fn(_) { Ok(0) },
      stats: fn() { Ok(storage.Stats(0, 0, 0)) },
      health: fn() { Ok(Nil) },
    )
  let configured =
    runtime.new(
      storage: persistent,
      clock: runtime.Clock(fn() { 100 }),
      ids: runtime.IdGenerator(fn() { "Collision001" }),
      retention_seconds: 43_200,
    )
  let assert Ok(alerts) = topic.parse("alerts")

  let assert Error(service.Persistence(storage.Conflict(_))) =
    service.publish(message.plaintext_draft(alerts, "hello"), configured)
}

fn result_unwrap(result: Result(a, Nil), message: String) -> a {
  let assert Ok(value) = result as message
  value
}

pub fn sqlite_atomic_commit_rolls_back_message_when_outbox_insert_fails_test() {
  let assert Ok(directory) = filesystem.temporary_directory()
  let path = directory <> "/notify.db"
  let assert Ok(adapter) = sqlite.start_adapter(path)
  let assert Ok(outbox) = delivery_sqlite.start(path)
  let duplicate =
    delivery.NewJob(
      id: "duplicate-job",
      kind: delivery.MobileRelay,
      endpoint: "https://relay.example/hash",
      payload: <<>>,
      message_id: "Existing01XY",
      topic_hash: "hash",
      available_at: 100,
    )
  let assert Ok(_) = outbox.enqueue(duplicate)
  let assert Ok(topic) = topic.parse("atomic")
  let candidate =
    message.Message(
      id: "Atomic0001XY",
      time: 100,
      expires: None,
      event: message.MessageEvent,
      topic:,
      message: "must roll back",
      title: None,
      priority: message.Default,
      tags: [],
      markdown: False,
      icon: None,
      click: None,
      actions: [],
      attachment: None,
      scheduled: False,
      cached: True,
      sequence_id: None,
    )
  let storage.AtomicCommit(commit) = adapter.commit
  assert commit(candidate, [duplicate]) |> result_is_error
  let assert Ok(messages) =
    adapter.storage.query(storage.Query(
      topics: [topic],
      since: storage.All,
      include_scheduled: False,
      criteria: filter.none(),
    ))
  assert list.is_empty(messages)
}

fn result_is_error(value: Result(a, e)) -> Bool {
  case value {
    Error(_) -> True
    Ok(_) -> False
  }
}
