import gleam/bit_array
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
import notify/storage
import notify/storage/sqlite

pub fn storage_failure_returns_503_and_does_not_fan_out_test() {
  let storage =
    storage.Storage(
      migrate: fn() { Ok(Nil) },
      save: fn(_) { Error(storage.Unavailable("database offline")) },
      query: fn(_) { Ok([]) },
      release_due: fn(_, _) { Ok([]) },
      cleanup_expired: fn(_) { Ok(0) },
      stats: fn() { Ok(storage.Stats(0, 0, 0)) },
      health: fn() { Error(storage.Unavailable("database offline")) },
    )
  let runtime =
    runtime.new(
      storage:,
      clock: runtime.Clock(fn() { 1_725_000_000 }),
      ids: runtime.IdGenerator(fn() { "AbCdEf1234" }),
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
      message_id: "Existing01",
      topic_hash: "hash",
      available_at: 100,
    )
  let assert Ok(_) = outbox.enqueue(duplicate)
  let assert Ok(topic) = topic.parse("atomic")
  let candidate =
    message.Message(
      id: "Atomic0001",
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
