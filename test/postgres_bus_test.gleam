import gleam/erlang/process
import gleam/option.{None}
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
    )
  assert postgres_bus.drain_once(adapter, "node-a", fn(message) {
      process.send(deliveries, message.id)
    })
    == Ok(3)
  assert process.receive(deliveries, 100) == Ok("Cluster003")
  assert process.receive(deliveries, 10) == Error(Nil)
  assert process.receive(acknowledgements, 100) == Ok(#("node-a", 3))
}
