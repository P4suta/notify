import gleam/dynamic/decode
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import notify/attachment_store/filesystem
import notify/core/filter
import notify/core/message
import notify/core/topic
import notify/storage
import notify/storage/sqlite
import sqlight

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
  let one = fixture("S000000001XY", 100, "one")
  let two = fixture("S000000002XY", 101, "two")
  let three = fixture("S000000003XY", 102, "one")
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
      "S000000001XY",
      "S000000003XY",
    ]
}

pub fn sqlite_rejects_duplicate_ids_without_partial_message_test() {
  let assert Ok(store) = sqlite.start(":memory:")
  let value = fixture("S000000004XY", 100, "one")
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
      ..fixture("S000000005XY", 100, "one"),
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
          id: Some("Action0001"),
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

pub fn sqlite_attachment_reference_is_scoped_to_its_message_topic_test() {
  let assert Ok(store) = sqlite.start(":memory:")
  let key = string.repeat("a", times: 64)
  let attached =
    message.Message(
      ..fixture("SAttach001XY", 100, "one"),
      attachment: Some(message.Attachment(
        name: "report.txt",
        url: "https://notify.example/file/one/" <> key <> "/report.txt",
        mime_type: Some("text/plain"),
        size: Some(12),
        expires: Some(200),
      )),
    )
  assert store.save(attached) == Ok(attached)
  let assert Ok(one) = topic.parse("one")
  let assert Ok(other) = topic.parse("other")
  assert store.has_attachment(one, key) == Ok(True)
  assert store.has_attachment(other, key) == Ok(False)
  assert store.has_attachment(one, string.repeat("b", times: 64)) == Ok(False)
}

pub fn sqlite_claims_each_due_message_only_once_test() {
  let assert Ok(store) = sqlite.start(":memory:")
  let scheduled =
    message.Message(..fixture("S000000006XY", 200, "one"), scheduled: True)
  assert store.save(scheduled) == Ok(scheduled)
  let assert Ok(before) = store.stats()
  assert before.events == 1

  assert store.release_due(199, 10) == Ok([])
  let assert Ok([released]) = store.release_due(200, 10)
  assert released.scheduled == False
  assert released.id == scheduled.id
  let assert Ok(after) = store.stats()
  assert after.events == 2
  assert store.release_due(200, 10) == Ok([])
}

pub fn sqlite_cleanup_cascades_expired_message_event_rows_test() {
  let assert Ok(store) = sqlite.start(":memory:")
  let expired =
    message.Message(..fixture("S000000007XY", 100, "one"), expires: Some(110))
  let current =
    message.Message(..fixture("S000000008XY", 101, "one"), expires: Some(200))
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

pub fn sqlite_pages_large_queries_without_changing_since_semantics_test() {
  let assert Ok(store) = sqlite.start(":memory:")
  save_page_fixtures(store, 1, 300)
  let assert Ok(paged) = topic.parse("paged")

  let assert Ok(all) =
    store.query(storage.Query(
      topics: [paged],
      since: storage.All,
      include_scheduled: False,
      criteria: filter.none(),
    ))
  assert list.length(all) == 300
  assert list.first(all) == Ok(page_fixture(1))
  assert list.last(all) == Ok(page_fixture(300))

  let assert Ok(after_page_boundary) =
    store.query(storage.Query(
      topics: [paged],
      since: storage.AfterId(page_id(256)),
      include_scheduled: False,
      criteria: filter.none(),
    ))
  assert list.length(after_page_boundary) == 44
  assert list.first(after_page_boundary) == Ok(page_fixture(257))

  let assert Ok(latest) =
    store.query(storage.Query(
      topics: [paged],
      since: storage.Latest,
      include_scheduled: True,
      criteria: filter.Criteria(
        ..filter.none(),
        message: Some("message-" <> page_id(300)),
      ),
    ))
  assert latest == [page_fixture(300)]
}

pub fn sqlite_refuses_an_unrecognised_schema_without_modifying_it_test() {
  let assert Ok(directory) = filesystem.temporary_directory()
  let path = directory <> "/ntfy-cache.db"
  let assert Ok(connection) = sqlight.open(path)
  assert sqlight.exec(
      "CREATE TABLE schemaVersion (id INTEGER PRIMARY KEY, version INTEGER NOT NULL); INSERT INTO schemaVersion VALUES (1, 15); CREATE TABLE messages (id INTEGER PRIMARY KEY, mid TEXT NOT NULL, topic TEXT NOT NULL, message TEXT NOT NULL)",
      connection,
    )
    == Ok(Nil)
  assert sqlight.close(connection) == Ok(Nil)

  let assert Error(storage.UnsupportedSchema(detail)) = sqlite.start(path)
  assert string.contains(detail, "notify migrate ntfy")
  assert string.contains(detail, "reset")

  let assert Ok(unchanged) = sqlight.open(path)
  let assert Ok(tables) =
    sqlight.query(
      "SELECT name FROM sqlite_schema WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
      on: unchanged,
      with: [],
      expecting: {
        use name <- decode.field(0, decode.string)
        decode.success(name)
      },
    )
  assert tables == ["messages", "schemaVersion"]
  assert sqlight.close(unchanged) == Ok(Nil)
}

fn save_page_fixtures(store: storage.Storage, current: Int, count: Int) -> Nil {
  case current > count {
    True -> Nil
    False -> {
      let value = page_fixture(current)
      assert store.save(value) == Ok(value)
      save_page_fixtures(store, current + 1, count)
    }
  }
}

fn page_fixture(index: Int) -> message.Message {
  fixture(page_id(index), index, "paged")
}

fn page_id(index: Int) -> String {
  "P" <> string.pad_start(int.to_string(index), to: 11, with: "0")
}
