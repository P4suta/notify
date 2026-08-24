import gleam/bit_array
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import notify/delivery
import notify/delivery/memory
import notify/delivery/relay
import notify/delivery/sqlite
import notify/delivery/worker

fn pending(id: String) -> delivery.NewJob {
  delivery.NewJob(
    id:,
    kind: delivery.MobileRelay,
    endpoint: "https://upstream.example/v1/relay",
    payload: <<"{}":utf8>>,
    message_id: "Message001",
    topic_hash: "hash",
    available_at: 100,
  )
}

pub fn lease_expiry_retry_and_dead_letter_contract_test() {
  let assert Ok(outbox) = memory.start()
  let assert Ok(_) = outbox.enqueue(pending("job-1"))

  let assert Ok([first]) =
    outbox.claim(delivery.MobileRelay, "worker-a", 100, 30, 10)
  assert first.state == delivery.Leased
  assert first.lease_until == Some(130)
  assert outbox.claim(delivery.MobileRelay, "worker-b", 120, 30, 10) == Ok([])

  let assert Ok([reclaimed]) =
    outbox.claim(delivery.MobileRelay, "worker-b", 130, 30, 10)
  assert reclaimed.lease_owner == Some("worker-b")
  let assert Ok(retry) =
    outbox.fail("job-1", "worker-b", 131, "upstream unavailable", 2, 10)
  assert retry.state == delivery.Pending
  assert retry.attempts == 1
  let retry_at = 131 + delivery.retry_delay_with_jitter(10, 1, "job-1")
  assert retry.available_at == retry_at
  assert outbox.claim(delivery.MobileRelay, "worker-a", retry_at - 1, 30, 10)
    == Ok([])

  let assert Ok([second]) =
    outbox.claim(delivery.MobileRelay, "worker-a", retry_at, 30, 10)
  let assert Ok(dead) =
    outbox.fail(second.id, "worker-a", 142, "still unavailable", 2, 10)
  assert dead.state == delivery.DeadLetter
  assert dead.attempts == 2
  assert outbox.claim(delivery.MobileRelay, "worker-a", 1000, 30, 10) == Ok([])
}

pub fn completion_requires_current_lease_owner_test() {
  let assert Ok(outbox) = memory.start()
  let assert Ok(_) = outbox.enqueue(pending("job-2"))
  let assert Ok(_) = outbox.claim(delivery.MobileRelay, "worker-a", 100, 30, 1)
  assert outbox.complete("job-2", "worker-b") == Error(delivery.LeaseLost)
  assert outbox.complete("job-2", "worker-a") == Ok(Nil)
  let assert Ok(jobs) = outbox.list(delivery.MobileRelay)
  assert list.is_empty(jobs)
}

pub fn sqlite_outbox_implements_lease_and_completion_contract_test() {
  let assert Ok(outbox) = sqlite.start(":memory:")
  let assert Ok(_) = outbox.enqueue(pending("sqlite-job"))
  let assert Ok([claimed]) =
    outbox.claim(delivery.MobileRelay, "sqlite-worker", 100, 30, 1)
  assert claimed.lease_until == Some(130)
  assert outbox.complete(claimed.id, "other-worker")
    == Error(delivery.LeaseLost)
  assert outbox.complete(claimed.id, "sqlite-worker") == Ok(Nil)
  assert outbox.list(delivery.MobileRelay) == Ok([])
  assert outbox.health() == Ok(Nil)
}

fn management_contract(outbox: delivery.Store) {
  let assert Ok(_) = outbox.enqueue(pending("managed-job"))
  let assert Ok([claimed]) =
    outbox.claim(delivery.MobileRelay, "worker", 100, 30, 1)
  let assert Ok(dead) =
    outbox.fail(claimed.id, "worker", 101, "permanent failure", 1, 10)
  assert dead.state == delivery.DeadLetter

  let assert Ok(before) = outbox.stats()
  assert before.mobile_relay_dead_letter == 1
  assert before.mobile_relay_pending == 0

  let assert Ok(requeued) = outbox.requeue("managed-job", 200)
  assert requeued.state == delivery.Pending
  assert requeued.attempts == 0
  assert requeued.available_at == 200
  assert requeued.lease_owner == None
  assert requeued.lease_until == None
  assert requeued.last_error == Some("permanent failure")
  assert outbox.purge("managed-job") == Error(delivery.Conflict)

  let assert Ok([retried]) =
    outbox.claim(delivery.MobileRelay, "worker", 200, 30, 1)
  let assert Ok(_) =
    outbox.fail(retried.id, "worker", 201, "failed again", 1, 10)
  assert outbox.purge("managed-job") == Ok(Nil)
  assert outbox.purge("managed-job") == Error(delivery.NotFound)
  let assert Ok(after) = outbox.stats()
  assert after.mobile_relay_dead_letter == 0
}

pub fn memory_outbox_supports_manual_requeue_purge_and_stats_test() {
  let assert Ok(outbox) = memory.start()
  management_contract(outbox)
}

pub fn sqlite_outbox_supports_manual_requeue_purge_and_stats_test() {
  let assert Ok(outbox) = sqlite.start(":memory:")
  management_contract(outbox)
}

pub fn retry_backoff_has_bounded_deterministic_jitter_test() {
  let first = delivery.retry_delay_with_jitter(10, 1, "job-a")
  assert first == delivery.retry_delay_with_jitter(10, 1, "job-a")
  assert first >= 5
  assert first <= 10
  assert delivery.retry_delay_with_jitter(10, 20, "job-a") <= 3600
  assert delivery.retry_delay_with_jitter(10, 20, "job-a") >= 1800
}

pub fn relay_payload_contains_no_message_content_or_topic_url_test() {
  let payload =
    relay.payload(
      message_id: "Message001",
      topic_url: "https://notify.example/private-alerts",
    )
  let assert Ok(text) = bit_array.to_string(payload)
  assert string.contains(text, "\"message_id\":\"Message001\"")
  assert string.contains(text, "\"topic_url_hash\":")
  assert !string.contains(text, "private-alerts")
  assert !string.contains(text, "message\"")
}

pub fn worker_records_retry_without_losing_the_durable_job_test() {
  let assert Ok(outbox) = memory.start()
  let assert Ok(_) = outbox.enqueue(pending("worker-job"))
  let provider =
    worker.Provider(kind: delivery.MobileRelay, deliver: fn(_) {
      Error("HTTP 503")
    })
  let assert Ok(report) =
    worker.run_once(
      outbox,
      provider,
      worker_id: "worker-a",
      now: 100,
      lease_seconds: 30,
      limit: 10,
      max_attempts: 3,
      base_delay_seconds: 10,
    )
  assert report.claimed == 1
  assert report.delivered == 0
  assert report.retried == 1
  assert report.dead_lettered == 0
  let assert Ok([job]) = outbox.list(delivery.MobileRelay)
  assert job.last_error == Some("HTTP 503")
}

pub fn mobile_relay_provider_sends_only_poll_id_and_prehashed_endpoint_test() {
  let sender =
    relay.Sender(fn(endpoint, token, poll_id) {
      assert endpoint == "https://upstream.example/safe-topic-hash"
      assert token == "tk_upstream"
      assert poll_id == "Message001"
      Ok(200)
    })
  let provider = relay.provider("tk_upstream", sender)
  let private_job =
    delivery.job_from_new(delivery.NewJob(
      id: "relay-private",
      kind: delivery.MobileRelay,
      endpoint: "https://upstream.example/safe-topic-hash",
      payload: <<"this content must never leave":utf8>>,
      message_id: "Message001",
      topic_hash: "safe-topic-hash",
      available_at: 100,
    ))
  assert provider.deliver(private_job) == Ok(Nil)
}

pub fn mobile_relay_quota_response_is_retryable_test() {
  let provider = relay.provider("", relay.Sender(fn(_, _, _) { Ok(429) }))
  assert provider.deliver(delivery.job_from_new(pending("relay-quota")))
    == Error("mobile relay HTTP 429")
}
