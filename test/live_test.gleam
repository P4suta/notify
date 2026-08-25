import notify/core/filter
import notify/core/topic
import notify/http/live
import notify/runtime
import notify/storage

pub fn replay_query_failure_is_not_converted_to_an_empty_success_test() {
  let unavailable =
    storage.Storage(
      migrate: fn() { Ok(Nil) },
      save: fn(message) { Ok(message) },
      query: fn(_) { Error(storage.Unavailable("database offline")) },
      has_attachment: fn(_, _) { Ok(False) },
      release_due: fn(_, _) { Ok([]) },
      cleanup_expired: fn(_) { Ok(0) },
      stats: fn() { Ok(storage.Stats(0, 0, 0)) },
      health: fn() { Error(storage.Unavailable("database offline")) },
    )
  let configured =
    runtime.new(
      storage: unavailable,
      clock: runtime.Clock(fn() { 100 }),
      ids: runtime.IdGenerator(fn() { "L000000001XY" }),
      retention_seconds: 43_200,
    )
  let assert Ok(alerts) = topic.parse("alerts")

  assert live.replay_messages(
      configured,
      [alerts],
      filter.none(),
      storage.All,
      False,
    )
    == Error(storage.Unavailable("database offline"))
}
