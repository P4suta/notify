import gleam/option.{None}
import notify/delivery
import notify/runtime
import notify/webpush
import notify/webpush/memory
import notify/webpush/provider

fn configured() -> #(webpush.Store, runtime.WebPushRuntime, String) {
  let assert Ok(store) = memory.start(max_endpoints_per_ip: 10)
  let endpoint = "https://fcm.googleapis.com/fcm/send/browser-token"
  let assert Ok(_) =
    store.upsert(webpush.NewSubscription(
      id: "wps_provider",
      endpoint:,
      auth: "kSC3T8aN1JCQxxPdrFLrZg",
      p256dh: "BMKKbxdUU_xLS7G1Wh5AN8PvWOjCzkCuKZYb8apcqYrDxjOF_2piggBnoJLQYx9IeSD70fNuwawI3e9Y8m3S3PE",
      topics: ["alerts"],
      user_id: None,
      subscriber_ip: "192.0.2.30",
      now: 100,
    ))
  #(
    store,
    runtime.WebPushRuntime(
      store:,
      public_key: "public",
      private_key: "private",
      subscriber: "admin@example.test",
    ),
    endpoint,
  )
}

fn job(endpoint: String) -> delivery.Job {
  delivery.job_from_new(delivery.NewJob(
    id: "job-provider",
    kind: delivery.WebPush,
    endpoint:,
    payload: <<"payload":utf8>>,
    message_id: "Message001",
    topic_hash: "hash",
    available_at: 100,
  ))
}

pub fn gone_endpoint_is_removed_and_job_can_complete_test() {
  let #(store, configured, endpoint) = configured()
  let sender = provider.Sender(fn(_, _, _, _, _, _, _, _, _) { Ok(410) })
  let delivery_provider = provider.new(configured, sender, fn() { 100 })
  assert delivery_provider.deliver(job(endpoint)) == Ok(Nil)
  assert store.by_endpoint(endpoint) == Error(webpush.NotFound)
}

pub fn push_service_failure_is_retried_without_removing_subscription_test() {
  let #(store, configured, endpoint) = configured()
  let sender = provider.Sender(fn(_, _, _, _, _, _, _, _, _) { Ok(503) })
  let delivery_provider = provider.new(configured, sender, fn() { 100 })
  assert delivery_provider.deliver(job(endpoint)) == Error("Web Push HTTP 503")
  let assert Ok(_) = store.by_endpoint(endpoint)
}

pub fn missing_subscription_makes_stale_outbox_job_complete_test() {
  let #(_, configured, endpoint) = configured()
  let assert Ok(_) = configured.store.remove_endpoint(endpoint)
  let sender =
    provider.Sender(fn(_, _, _, _, _, _, _, _, _) {
      panic as "sender must not be called"
    })
  let delivery_provider = provider.new(configured, sender, fn() { 100 })
  assert delivery_provider.deliver(job(endpoint)) == Ok(Nil)
}
