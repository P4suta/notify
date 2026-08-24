import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import notify/attachment_store
import notify/attachment_store/postgres as attachment_postgres
import notify/core/filter
import notify/core/message
import notify/core/topic
import notify/delivery
import notify/delivery/postgres as delivery_postgres
import notify/identity/postgres as identity_postgres
import notify/rate_limit
import notify/storage
import notify/storage/postgres
import notify/webpush as webpush_model
import notify/webpush/postgres as webpush_postgres
import postgleam/config

fn test_config() -> Result(config.Config, Nil) {
  use host <- result.try(getenv("NOTIFY_TEST_POSTGRES_HOST"))
  let port = case getenv("NOTIFY_TEST_POSTGRES_PORT") {
    Ok(value) -> int.parse(value) |> result.unwrap(5432)
    Error(_) -> 5432
  }
  let password = case getenv("NOTIFY_TEST_POSTGRES_PASSWORD") {
    Ok(value) -> value
    Error(_) -> "notify-test-password"
  }
  Ok(
    config.default()
    |> config.host(host)
    |> config.port(port)
    |> config.database("notify")
    |> config.username("notify")
    |> config.password(password),
  )
}

fn fixture(id: String, scheduled: Bool, timestamp: Int) -> message.Message {
  let assert Ok(topic) = topic.parse("postgres-contract")
  message.Message(
    id:,
    time: timestamp,
    expires: Some(10_000),
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
    scheduled:,
    cached: True,
    sequence_id: None,
  )
}

pub fn postgres_adapters_share_their_contract_on_a_real_database_test() {
  case test_config() {
    Error(_) -> Nil
    Ok(configuration) -> {
      let assert Ok(adapter_a) = postgres.start(configuration, "node-a")
      let postgres.Adapter(storage: messages, ..) = adapter_a
      assert messages.health() == Ok(Nil)

      let first = fixture("PgStore001XY", False, 100)
      let delayed = fixture("PgDelay001XY", True, 200)
      assert messages.save(first) == Ok(first)
      assert messages.save(delayed) == Ok(delayed)
      let assert Ok(topic) = topic.parse("postgres-contract")
      let assert Ok(before) =
        messages.query(storage.Query(
          topics: [topic],
          since: storage.All,
          include_scheduled: False,
          criteria: filter.none(),
        ))
      assert list.map(before, fn(value) { value.id }) == ["PgStore001XY"]
      let assert Ok(released) = messages.release_due(200, 10)
      assert list.map(released, fn(value) { value.id }) == ["PgDelay001XY"]

      let expired =
        message.Message(
          ..fixture("PgExpire01XY", False, 109),
          expires: Some(110),
        )
      assert messages.save(expired) == Ok(expired)

      let assert Ok(adapter_b) = postgres.start(configuration, "node-b")
      let postgres.Adapter(fetch_events:, ack_events:, ..) = adapter_b
      let assert Ok(events) = fetch_events("node-b", 100)
      assert list.any(events, fn(event) { event.message.id == "PgStore001XY" })
      let assert Ok(last) = list.last(events)
      assert ack_events("node-b", last.sequence) == Ok(Nil)
      assert fetch_events("node-b", 100) == Ok([])

      let assert Ok(before_cleanup) = messages.stats()
      assert messages.cleanup_expired(110) == Ok(1)
      let assert Ok(after_cleanup) = messages.stats()
      assert after_cleanup.messages == before_cleanup.messages - 1
      assert after_cleanup.events == before_cleanup.events - 1

      save_page_fixtures(messages, 1, 260)
      let assert Ok(page_topic) = topic.parse("postgres-page")
      let assert Ok(pages) =
        messages.query(storage.Query(
          topics: [page_topic],
          since: storage.All,
          include_scheduled: False,
          criteria: filter.none(),
        ))
      assert list.length(pages) == 260
      assert list.first(pages) == Ok(page_fixture(1))
      assert list.last(pages) == Ok(page_fixture(260))
      let assert Ok(after_page) =
        messages.query(storage.Query(
          topics: [page_topic],
          since: storage.AfterId(page_id(256)),
          include_scheduled: False,
          criteria: filter.none(),
        ))
      assert list.length(after_page) == 4
      assert list.first(after_page) == Ok(page_fixture(257))

      let assert Ok(identity_postgres.Started(identity, Some(_))) =
        identity_postgres.start(configuration, fn() { 1000 }, fn() {
          "abcdefghijklmnopqrstuvwxyz123"
        })
      assert identity.setup_required() == Ok(True)

      let assert Ok(blobs) =
        attachment_postgres.start(
          configuration,
          max_file_bytes: 10,
          max_total_bytes: 20,
        )
      let assert Ok(stored) =
        blobs.put(attachment_store.Upload(<<"abcdef":utf8>>, expires: 100))
      let assert Ok(partial) =
        blobs.get(
          stored.key,
          Some(attachment_store.ByteRange(start: 1, end: 3)),
        )
      assert partial.data == <<"bcd":utf8>>
      assert blobs.cleanup(100) == Ok(1)

      let assert Ok(outbox) = delivery_postgres.start(configuration)
      let assert Ok(_) =
        outbox.enqueue(delivery.NewJob(
          id: "postgres-job",
          kind: delivery.MobileRelay,
          endpoint: "https://relay.example",
          payload: <<"{}":utf8>>,
          message_id: "PgStore001XY",
          topic_hash: "hash",
          available_at: 100,
        ))
      let assert Ok([claimed]) =
        outbox.claim(delivery.MobileRelay, "node-a", 100, 30, 1)
      assert claimed.lease_until == Some(130)
      let assert Ok(dead) =
        outbox.fail(claimed.id, "node-a", 101, "HTTP 503", 1, 10)
      assert dead.state == delivery.DeadLetter
      let assert Ok(delivery_stats) = outbox.stats()
      assert delivery_stats.mobile_relay_dead_letter == 1
      let assert Ok(requeued) = outbox.requeue(claimed.id, 200)
      assert requeued.state == delivery.Pending
      assert requeued.attempts == 0
      let assert Ok([claimed_again]) =
        outbox.claim(delivery.MobileRelay, "node-b", 200, 30, 1)
      let assert Ok(_) =
        outbox.fail(claimed_again.id, "node-b", 201, "HTTP 503", 1, 10)
      assert outbox.purge(claimed.id) == Ok(Nil)
      assert outbox.list(delivery.MobileRelay) == Ok([])

      let assert Ok(webpush_store) =
        webpush_postgres.start(configuration, max_endpoints_per_ip: 10)
      let endpoint =
        "https://updates.push.services.mozilla.com/wpush/v2/postgres-contract"
      assert webpush_store.remove_endpoint(endpoint) == Ok(Nil)
      let assert Ok(saved_subscription) =
        webpush_store.upsert(webpush_model.NewSubscription(
          id: "wps_postgres",
          endpoint:,
          auth: "kSC3T8aN1JCQxxPdrFLrZg",
          p256dh: "BMKKbxdUU_xLS7G1Wh5AN8PvWOjCzkCuKZYb8apcqYrDxjOF_2piggBnoJLQYx9IeSD70fNuwawI3e9Y8m3S3PE",
          topics: ["postgres-contract"],
          user_id: None,
          subscriber_ip: "192.0.2.10",
          now: 100,
        ))
      assert saved_subscription.id == "wps_postgres"
      let assert Ok([pg_subscription]) =
        webpush_store.for_topic("postgres-contract")
      assert pg_subscription.endpoint == endpoint
      assert webpush_store.remove_endpoint(endpoint) == Ok(Nil)

      let assert Ok(limiter_a) =
        rate_limit.postgres(configuration, requests: 2, window_seconds: 60)
      let assert Ok(limiter_b) =
        rate_limit.postgres(configuration, requests: 2, window_seconds: 60)
      assert limiter_a.check("distributed-contract", 600)
        == Ok(rate_limit.Allowed(remaining: 1, reset_at: 660))
      assert limiter_b.check("distributed-contract", 600)
        == Ok(rate_limit.Allowed(remaining: 0, reset_at: 660))
      assert limiter_a.check("distributed-contract", 600)
        == Ok(rate_limit.Limited(retry_after: 60, reset_at: 660))
    }
  }
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
  let assert Ok(page_topic) = topic.parse("postgres-page")
  message.Message(..fixture(page_id(index), False, index), topic: page_topic)
}

fn page_id(index: Int) -> String {
  "P" <> string.pad_start(int.to_string(index), to: 11, with: "0")
}

@external(erlang, "notify_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)
