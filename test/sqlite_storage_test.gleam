import gleam/list
import gleam/option.{None, Some}
import notify/core/filter
import notify/core/message
import notify/core/topic
import notify/storage
import notify/storage/sqlite

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
  )
}

pub fn sqlite_storage_implements_the_shared_ordering_contract_test() {
  let assert Ok(store) = sqlite.start(":memory:")
  let one = fixture("S000000001", 100, "one")
  let two = fixture("S000000002", 101, "two")
  let three = fixture("S000000003", 102, "one")
  assert store.save(one) == Ok(one)
  assert store.save(two) == Ok(two)
  assert store.save(three) == Ok(three)

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
      "S000000001",
      "S000000003",
    ]
}

pub fn sqlite_rejects_duplicate_ids_without_partial_message_test() {
  let assert Ok(store) = sqlite.start(":memory:")
  let value = fixture("S000000004", 100, "one")
  assert store.save(value) == Ok(value)
  let assert Error(storage.Conflict(_)) = store.save(value)

  let assert Ok(one_topic) = topic.parse("one")
  let assert Ok(messages) =
    store.query(storage.Query(
      topics: [one_topic],
      since: storage.All,
      include_scheduled: False,
      criteria: filter.none(),
    ))
  assert list.length(messages) == 1
}

pub fn sqlite_round_trips_complete_wire_payload_test() {
  let assert Ok(store) = sqlite.start(":memory:")
  let complete =
    message.Message(
      ..fixture("S000000005", 100, "one"),
      title: Some("Report"),
      priority: message.High,
      tags: ["warning"],
      markdown: True,
      actions: [
        message.HttpAction(
          label: "Ack",
          url: "https://example.test/ack",
          method: "POST",
          headers: [#("x-api-key", "test")],
          body: Some("ack=true"),
          clear: True,
        ),
      ],
      attachment: Some(message.Attachment(
        name: "report.txt",
        url: "https://example.test/report.txt",
        mime_type: Some("text/plain"),
        size: Some(12),
        expires: Some(200),
      )),
    )
  assert store.save(complete) == Ok(complete)

  let assert Ok(one_topic) = topic.parse("one")
  let assert Ok([loaded]) =
    store.query(storage.Query(
      topics: [one_topic],
      since: storage.All,
      include_scheduled: False,
      criteria: filter.none(),
    ))
  assert loaded == complete
}

pub fn sqlite_claims_each_due_message_only_once_test() {
  let assert Ok(store) = sqlite.start(":memory:")
  let scheduled =
    message.Message(..fixture("S000000006", 200, "one"), scheduled: True)
  assert store.save(scheduled) == Ok(scheduled)

  assert store.release_due(199, 10) == Ok([])
  let assert Ok([released]) = store.release_due(200, 10)
  assert released.scheduled == False
  assert released.id == scheduled.id
  assert store.release_due(200, 10) == Ok([])
}

pub fn sqlite_cleanup_cascades_expired_message_event_rows_test() {
  let assert Ok(store) = sqlite.start(":memory:")
  let expired =
    message.Message(..fixture("S000000007", 100, "one"), expires: Some(110))
  let current =
    message.Message(..fixture("S000000008", 101, "one"), expires: Some(200))
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
