import gleam/erlang/process
import gleam/option.{None}
import notify/cluster/health as cluster_health
import notify/cluster/postgres_bus
import notify/core/message
import notify/core/topic
import notify/storage
import notify/storage/memory
import notify/storage/postgres

fn fixture(id: String, scheduled: Bool) -> message.Message {
  let assert Ok(topic) = topic.parse("alerts")
  message.Message(
    id:,
    time: 100,
    expires: None,
    event: message.MessageEvent,
    topic:,
    message: id,
    title: None,
    priority: message.Default,
    tags: [],
    markdown: False,
    icon: None,
    click: None,
    actions: [],
    attachment: None,
    scheduled:,
    cached: True,
    sequence_id: None,
  )
}

pub fn durable_cluster_drain_skips_local_and_scheduled_events_then_acks_test() {
  let assert Ok(store) = memory.start()
  let acknowledgements = process.new_subject()
  let deliveries = process.new_subject()
  let events = [
    postgres.ClusterEvent(1, "node-a", fixture("Cluster001", False)),
    postgres.ClusterEvent(2, "node-b", fixture("Cluster002", True)),
    postgres.ClusterEvent(3, "node-b", fixture("Cluster003", False)),
  ]
  let adapter =
    postgres.Adapter(
      storage: store,
      commit: storage.AtomicCommit(fn(message, _) { store.save(message) }),
      fetch_events: fn(_, _) { Ok(events) },
      ack_events: fn(node, sequence) {
        process.send(acknowledgements, #(node, sequence))
        Ok(Nil)
      },
      cluster_health: unavailable_cluster_health(),
      pool_size: 1,
    )
  assert postgres_bus.drain_once(adapter, "node-a", fn(message) {
      process.send(deliveries, message.id)
      Ok(Nil)
    })
    == Ok(3)
  assert process.receive(deliveries, 100) == Ok("Cluster003")
  assert process.receive(deliveries, 10) == Error(Nil)
  assert process.receive(acknowledgements, 100) == Ok(#("node-a", 3))
}

pub fn dispatch_failure_leaves_cursor_unacknowledged_for_retry_test() {
  let assert Ok(store) = memory.start()
  let acknowledgements = process.new_subject()
  let deliveries = process.new_subject()
  let events = [
    postgres.ClusterEvent(4, "node-b", fixture("Cluster004", False)),
    postgres.ClusterEvent(5, "node-b", fixture("Cluster005", False)),
  ]
  let adapter =
    postgres.Adapter(
      storage: store,
      commit: storage.AtomicCommit(fn(message, _) { store.save(message) }),
      fetch_events: fn(_, _) { Ok(events) },
      ack_events: fn(node, sequence) {
        process.send(acknowledgements, #(node, sequence))
        Ok(Nil)
      },
      cluster_health: unavailable_cluster_health(),
      pool_size: 1,
    )
  let dispatch_error = storage.Unavailable("broker dispatch rejected event")

  assert postgres_bus.drain_once(adapter, "node-a", fn(message) {
      case message.id {
        "Cluster005" -> Error(dispatch_error)
        _ -> {
          process.send(deliveries, message.id)
          Ok(Nil)
        }
      }
    })
    == Error(dispatch_error)
  assert process.receive(deliveries, 100) == Ok("Cluster004")
  assert process.receive(deliveries, 10) == Error(Nil)
  assert process.receive(acknowledgements, 10) == Error(Nil)
}

pub fn acknowledgement_failure_replays_the_batch_at_least_once_test() {
  let assert Ok(store) = memory.start()
  let deliveries = process.new_subject()
  let event = postgres.ClusterEvent(6, "node-b", fixture("Cluster006", False))
  let acknowledgement_error =
    storage.Unavailable("cursor acknowledgement failed")
  let adapter =
    postgres.Adapter(
      storage: store,
      commit: storage.AtomicCommit(fn(message, _) { store.save(message) }),
      fetch_events: fn(_, _) { Ok([event]) },
      ack_events: fn(_, _) { Error(acknowledgement_error) },
      cluster_health: unavailable_cluster_health(),
      pool_size: 1,
    )
  let dispatch = fn(notification: message.Message) {
    process.send(deliveries, notification.id)
    Ok(Nil)
  }

  assert postgres_bus.drain_once(adapter, "node-a", dispatch)
    == Error(acknowledgement_error)
  assert postgres_bus.drain_once(adapter, "node-a", dispatch)
    == Error(acknowledgement_error)
  assert process.receive(deliveries, 100) == Ok("Cluster006")
  assert process.receive(deliveries, 100) == Ok("Cluster006")
}

fn unavailable_cluster_health() -> cluster_health.Store {
  cluster_health.Store(fn(_, _) {
    Error(cluster_health.Unavailable("not configured in broker unit test"))
  })
}
