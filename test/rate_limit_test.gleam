import gleam/erlang/process
import gleam/list
import notify/rate_limit

pub fn fixed_window_has_exact_boundary_and_retry_metadata_test() {
  let assert Ok(limiter) = rate_limit.memory(requests: 2, window_seconds: 10)

  assert limiter.check("203.0.113.4", 100)
    == Ok(rate_limit.Allowed(remaining: 1, reset_at: 110))
  assert limiter.check("203.0.113.4", 109)
    == Ok(rate_limit.Allowed(remaining: 0, reset_at: 110))
  assert limiter.check("203.0.113.4", 109)
    == Ok(rate_limit.Limited(retry_after: 1, reset_at: 110))
  assert limiter.check("203.0.113.4", 110)
    == Ok(rate_limit.Allowed(remaining: 1, reset_at: 120))
}

pub fn clients_have_independent_budgets_test() {
  let assert Ok(limiter) = rate_limit.memory(requests: 1, window_seconds: 60)
  assert limiter.check("client-a", 120)
    == Ok(rate_limit.Allowed(remaining: 0, reset_at: 180))
  assert limiter.check("client-b", 120)
    == Ok(rate_limit.Allowed(remaining: 0, reset_at: 180))
}

pub fn concurrent_checks_never_exceed_the_configured_budget_test() {
  let assert Ok(limiter) = rate_limit.memory(requests: 7, window_seconds: 60)
  let replies = process.new_subject()
  list.repeat(Nil, times: 32)
  |> list.each(fn(_) {
    process.spawn(fn() { process.send(replies, limiter.check("same", 300)) })
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

fn receive_many(subject, remaining: Int, accumulated) {
  case remaining {
    0 -> accumulated
    _ -> {
      let assert Ok(decision) = process.receive(subject, 1000)
      receive_many(subject, remaining - 1, [decision, ..accumulated])
    }
  }
}
