import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
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

      let first = fixture("PgStore001", False, 100)
      let delayed = fixture("PgDelay001", True, 200)
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
      assert list.map(before, fn(value) { value.id }) == ["PgStore001"]
      let assert Ok(released) = messages.release_due(200, 10)
      assert list.map(released, fn(value) { value.id }) == ["PgDelay001"]

      let assert Ok(adapter_b) = postgres.start(configuration, "node-b")
      let postgres.Adapter(fetch_events:, ack_events:, ..) = adapter_b
      let assert Ok(events) = fetch_events("node-b", 100)
      assert list.any(events, fn(event) { event.message.id == "PgStore001" })
      let assert Ok(last) = list.last(events)
      assert ack_events("node-b", last.sequence) == Ok(Nil)
      assert fetch_events("node-b", 100) == Ok([])

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
          message_id: "PgStore001",
          topic_hash: "hash",
          available_at: 100,
        ))
      let assert Ok([claimed]) =
        outbox.claim(delivery.MobileRelay, "node-a", 100, 30, 1)
      assert claimed.lease_until == Some(130)
      assert outbox.complete(claimed.id, "node-a") == Ok(Nil)
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

@external(erlang, "notify_ffi", "getenv")
fn getenv(name: String) -> Result(String, Nil)
