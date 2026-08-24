import gleam/bit_array
import gleam/option.{None, Some}
import gleam/string
import notify/core/message
import notify/core/topic
import notify/delivery
import notify/delivery/memory as delivery_memory
import notify/runtime
import notify/service
import notify/storage/memory as storage_memory
import notify/webpush
import notify/webpush/memory as webpush_memory

fn configured_runtime(now: Int) -> runtime.Runtime {
  let assert Ok(messages) = storage_memory.start()
  let assert Ok(subscriptions) = webpush_memory.start(max_endpoints_per_ip: 10)
  let assert Ok(outbox) = delivery_memory.start()
  let endpoint = "https://fcm.googleapis.com/fcm/send/browser-token"
  let assert Ok(_) =
    subscriptions.upsert(webpush.NewSubscription(
      id: "wps_browser",
      endpoint:,
      auth: "kSC3T8aN1JCQxxPdrFLrZg",
      p256dh: "BMKKbxdUU_xLS7G1Wh5AN8PvWOjCzkCuKZYb8apcqYrDxjOF_2piggBnoJLQYx9IeSD70fNuwawI3e9Y8m3S3PE",
      topics: ["alerts"],
      user_id: None,
      subscriber_ip: "192.0.2.20",
      now:,
    ))
  runtime.new(
    storage: messages,
    clock: runtime.Clock(fn() { now }),
    ids: runtime.IdGenerator(fn() { "Message001XY" }),
    retention_seconds: 43_200,
  )
  |> runtime.with_deliveries(outbox)
  |> runtime.with_webpush(runtime.WebPushRuntime(
    store: subscriptions,
    public_key: "public",
    private_key: "private",
    subscriber: "admin@example.test",
  ))
}

pub fn committed_publish_enqueues_durable_webpush_before_returning_test() {
  let runtime = configured_runtime(100)
  let assert Ok(alerts) = topic.parse("alerts")
  let assert Ok(saved) =
    service.publish(message.plaintext_draft(alerts, "important body"), runtime)
  assert saved.id == "Message001XY"
  let assert Some(outbox) = runtime.deliveries
  let assert Ok([job]) = outbox.list(delivery.WebPush)
  assert job.id == "wp_Message001XY_wps_browser"
  assert job.endpoint == "https://fcm.googleapis.com/fcm/send/browser-token"
  assert job.message_id == "Message001XY"
  let assert Ok(payload) = bit_array.to_string(job.payload)
  assert string.contains(payload, "\"event\":\"message\"")
  assert string.contains(payload, "\"subscription_id\":\"/alerts\"")
  assert string.contains(payload, "important body")
}

pub fn scheduled_message_persists_delivery_job_with_due_availability_test() {
  let initial = configured_runtime(100)
  let assert Ok(alerts) = topic.parse("alerts")
  let draft =
    message.Draft(
      ..message.plaintext_draft(alerts, "later"),
      delay: Some("10s"),
    )
  let assert Ok(_) = service.publish(draft, initial)
  let assert Some(outbox) = initial.deliveries
  let assert Ok([pending]) = outbox.list(delivery.WebPush)
  assert pending.available_at == 110

  let due = runtime.Runtime(..initial, clock: runtime.Clock(fn() { 110 }))
  assert service.release_due(due, 10) == Ok(1)
  let assert Ok([same_job]) = outbox.list(delivery.WebPush)
  assert same_job.id == pending.id
}
