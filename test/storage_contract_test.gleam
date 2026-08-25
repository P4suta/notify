import gleam/list
import gleam/option.{None, Some}
import notify/core/filter
import notify/core/message
import notify/core/topic
import notify/storage
import notify/storage/memory

fn fixture(id: String, timestamp: Int, topic_name: String) -> message.Message {
  let assert Ok(topic) = topic.parse(topic_name)
  message.Message(
    id:,
    time: timestamp,
    expires: None,
    event: message.MessageEvent,
    topic:,
    message: "message-" <> id,
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
    poll_id: None,
  )
}

pub fn memory_storage_preserves_commit_order_and_topic_filter_test() {
  let assert Ok(store) = memory.start()
  let one = fixture("A000000001", 100, "one")
  let two = fixture("A000000002", 101, "two")
  let three = fixture("A000000003", 102, "one")
  assert Ok(one) == store.save(one)
  assert Ok(two) == store.save(two)
  assert Ok(three) == store.save(three)

  let assert Ok(one_topic) = topic.parse("one")
  let assert Ok(messages) =
    store.query(storage.Query(
      topics: [one_topic],
      since: storage.All,
      include_scheduled: False,
      criteria: filter.none(),
    ))
  assert list.map(messages, fn(message) { message.id })
    == [
      "A000000001",
      "A000000003",
    ]
}

pub fn memory_storage_cleanup_removes_only_expired_messages_test() {
  let assert Ok(store) = memory.start()
  let expired =
    message.Message(..fixture("A000000004", 100, "one"), expires: Some(110))
  let current =
    message.Message(..fixture("A000000005", 101, "one"), expires: Some(200))
  assert store.save(expired) == Ok(expired)
  assert store.save(current) == Ok(current)
  assert store.cleanup_expired(110) == Ok(1)
  let assert Ok(one) = topic.parse("one")
  let assert Ok(messages) =
    store.query(storage.Query(
      topics: [one],
      since: storage.All,
      include_scheduled: False,
      criteria: filter.none(),
    ))
  assert messages == [current]
}

pub fn memory_scheduler_release_appends_a_durable_event_test() {
  let assert Ok(store) = memory.start()
  let scheduled =
    message.Message(..fixture("A000000012XY", 200, "one"), scheduled: True)
  assert store.save(scheduled) == Ok(scheduled)
  let assert Ok(before) = store.stats()
  assert before.events == 1

  let assert Ok([released]) = store.release_due(200, 10)
  assert !released.scheduled
  let assert Ok(after) = store.stats()
  assert after.events == 2
}

pub fn since_latest_returns_latest_published_message_for_each_topic_test() {
  let values = [
    fixture("A000000006", 100, "one"),
    fixture("A000000007", 101, "two"),
    fixture("A000000008", 102, "one"),
    message.Message(..fixture("A000000009", 103, "two"), scheduled: True),
  ]
  let assert Ok(one) = topic.parse("one")
  let assert Ok(two) = topic.parse("two")
  let selected =
    storage.apply_query(
      values,
      storage.Query(
        topics: [one, two],
        since: storage.Latest,
        include_scheduled: True,
        criteria: filter.none(),
      ),
    )
  assert list.map(selected, fn(item) { item.id })
    == ["A000000007", "A000000008"]
}

pub fn since_unknown_id_matches_ntfy_and_returns_all_topic_messages_test() {
  let values = [
    fixture("A000000010", 100, "one"),
    fixture("A000000011", 101, "one"),
  ]
  let assert Ok(one) = topic.parse("one")
  let selected =
    storage.apply_query(
      values,
      storage.Query(
        topics: [one],
        since: storage.AfterId("Z000000099"),
        include_scheduled: False,
        criteria: filter.none(),
      ),
    )
  assert selected == values
}
