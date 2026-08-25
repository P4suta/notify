import gleam/erlang/process
import gleam/list
import notify/rate_limit

pub fn token_bucket_refills_continuously_and_reports_retry_metadata_test() {
  let assert Ok(limiter) = rate_limit.memory(requests: 2, window_seconds: 10)

  assert limiter.check(rate_limit.Request, "203.0.113.4", 100, 1)
    == Ok(rate_limit.Allowed(remaining: 1, reset_at: 105))
  assert limiter.check(rate_limit.Request, "203.0.113.4", 100, 1)
    == Ok(rate_limit.Allowed(remaining: 0, reset_at: 110))
  assert limiter.check(rate_limit.Request, "203.0.113.4", 100, 1)
    == Ok(rate_limit.Limited(retry_after: 5, reset_at: 110))
  assert limiter.check(rate_limit.Request, "203.0.113.4", 105, 1)
    == Ok(rate_limit.Allowed(remaining: 0, reset_at: 115))
}

pub fn clients_and_purpose_buckets_have_independent_budgets_test() {
  let assert Ok(limiter) =
    rate_limit.memory_with_policies(
      rate_limit.Policies(
        requests: 2,
        subscriptions: 1,
        topic_creations: 1,
        auth_failures: 1,
        attachment_mebibytes: 4,
        attachment_uploads: 1,
      ),
      window_seconds: 60,
    )
  assert limiter.check(rate_limit.Request, "client-a", 120, 1)
    == Ok(rate_limit.Allowed(remaining: 1, reset_at: 150))
  assert limiter.check(rate_limit.Request, "client-b", 120, 1)
    == Ok(rate_limit.Allowed(remaining: 1, reset_at: 150))
  assert limiter.check(rate_limit.Subscription, "client-a", 120, 1)
    == Ok(rate_limit.Allowed(remaining: 0, reset_at: 180))
  assert limiter.check(rate_limit.Subscription, "client-a", 120, 1)
    == Ok(rate_limit.Limited(retry_after: 60, reset_at: 180))
  assert limiter.check(rate_limit.AuthFailure, "client-a", 120, 1)
    == Ok(rate_limit.Allowed(remaining: 0, reset_at: 180))
}

pub fn weighted_cost_is_charged_atomically_test() {
  let assert Ok(limiter) = rate_limit.memory(requests: 4, window_seconds: 8)
  assert limiter.check(rate_limit.AttachmentBandwidth, "client-a", 200, 3)
    == Ok(rate_limit.Allowed(remaining: 1, reset_at: 206))
  assert limiter.check(rate_limit.AttachmentBandwidth, "client-a", 200, 2)
    == Ok(rate_limit.Limited(retry_after: 2, reset_at: 206))
  assert limiter.check(rate_limit.AttachmentBandwidth, "client-a", 202, 2)
    == Ok(rate_limit.Allowed(remaining: 0, reset_at: 210))
}

pub fn every_policy_capacity_must_be_positive_and_persistable_test() {
  let valid =
    rate_limit.Policies(
      requests: 1,
      subscriptions: 1,
      topic_creations: 1,
      auth_failures: 1,
      attachment_mebibytes: 1,
      attachment_uploads: 1,
    )
  assert rate_limit.memory_with_policies(
      rate_limit.Policies(..valid, auth_failures: 0),
      window_seconds: 60,
    )
    == Error(rate_limit.Unavailable(
      "rate limits and window must be positive and fit PostgreSQL BIGINT",
    ))
  assert rate_limit.memory_with_policies(
      rate_limit.Policies(..valid, requests: 9_223_372_036_854_775_807),
      window_seconds: 2,
    )
    == Error(rate_limit.Unavailable(
      "rate limits and window must be positive and fit PostgreSQL BIGINT",
    ))
}

pub fn concurrent_checks_never_exceed_the_configured_budget_test() {
  let assert Ok(limiter) = rate_limit.memory(requests: 7, window_seconds: 60)
  let replies = process.new_subject()
  list.repeat(Nil, times: 32)
  |> list.each(fn(_) {
    process.spawn(fn() {
      process.send(
        replies,
        limiter.check(rate_limit.TopicCreation, "same", 300, 1),
      )
    })
  })

  let decisions = receive_many(replies, 32, [])
  let allowed =
    decisions
    |> list.filter(fn(decision) {
      case decision {
        Ok(rate_limit.Allowed(..)) -> True
        _ -> False
      }
    })
    |> list.length
  assert allowed == 7
}

pub fn batch_preserves_bucket_order_and_stops_at_limit_test() {
  let assert Ok(limiter) = rate_limit.memory(requests: 1, window_seconds: 60)
  assert limiter.check_many(
      [
        #(rate_limit.Request, 1),
        #(rate_limit.TopicCreation, 2),
        #(rate_limit.Subscription, 1),
      ],
      "batch",
      400,
    )
    == Ok([
      #(rate_limit.Request, rate_limit.Allowed(remaining: 0, reset_at: 460)),
      #(
        rate_limit.TopicCreation,
        rate_limit.Limited(retry_after: 60, reset_at: 460),
      ),
    ])
  assert limiter.check(rate_limit.Subscription, "batch", 400, 1)
    == Ok(rate_limit.Allowed(remaining: 0, reset_at: 460))
}

fn receive_many(subject, remaining: Int, accumulated) {
  case remaining {
    0 -> accumulated
    _ -> {
      let assert Ok(decision) = process.receive(subject, 1000)
      receive_many(subject, remaining - 1, [decision, ..accumulated])
    }
  }
}
