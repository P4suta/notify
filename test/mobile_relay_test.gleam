import notify/core/message
import notify/core/topic
import notify/delivery
import notify/delivery/memory as delivery_memory
import notify/runtime
import notify/security/token
import notify/service
import notify/storage/memory as storage_memory

pub fn publish_enqueues_content_blind_ntfy_poll_request_test() {
  let assert Ok(messages) = storage_memory.start()
  let assert Ok(outbox) = delivery_memory.start()
  let runtime =
    runtime.new(
      storage: messages,
      clock: runtime.Clock(fn() { 100 }),
      ids: runtime.IdGenerator(fn() { "RelayMsg01" }),
      retention_seconds: 43_200,
    )
    |> runtime.with_deliveries(outbox)
    |> runtime.with_public_base_url("https://notify.example")
    |> runtime.with_relay(runtime.RelayRuntime(
      base_url: "https://upstream.example",
      token: "tk_relay_secret",
    ))
  let assert Ok(alerts) = topic.parse("alerts")
  let assert Ok(_) =
    service.publish(
      message.plaintext_draft(alerts, "must remain private"),
      runtime,
    )

  let topic_hash = token.digest("https://notify.example/alerts")
  let assert Ok([job]) = outbox.list(delivery.MobileRelay)
  assert job.endpoint == "https://upstream.example/" <> topic_hash
  assert job.message_id == "RelayMsg01"
  assert job.topic_hash == topic_hash
  assert job.payload == <<>>
}
