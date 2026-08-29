import gleam/erlang/process.{type Pid}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import notify/delivery.{type Job, type Store}

pub type Provider {
  Provider(kind: delivery.Kind, deliver: fn(Job) -> Result(Nil, String))
}

pub type Report {
  Report(claimed: Int, delivered: Int, retried: Int, dead_lettered: Int)
}

type ProviderResult {
  ProviderDelivered(Job)
  ProviderFailed(Job, String)
}

/// Runs a durable provider continuously. Leases make an interrupted worker
/// recoverable by another node after the lease expires.
pub fn start(
  outbox: Store,
  provider: Provider,
  worker_id: String,
  now: fn() -> Int,
  interval_milliseconds: Int,
) -> Pid {
  process.spawn(fn() {
    loop(outbox, provider, worker_id, now, max(100, interval_milliseconds))
  })
}

pub fn supervised(
  outbox: Store,
  provider: Provider,
  worker_id: String,
  now: fn() -> Int,
  interval_milliseconds: Int,
) -> ChildSpecification(Nil) {
  supervision.worker(fn() {
    let pid = start(outbox, provider, worker_id, now, interval_milliseconds)
    Ok(actor.Started(pid:, data: Nil))
  })
}

fn loop(
  outbox: Store,
  provider: Provider,
  worker_id: String,
  now: fn() -> Int,
  interval_milliseconds: Int,
) -> Nil {
  let outcome =
    run_once(
      outbox,
      provider,
      worker_id:,
      now: now(),
      lease_seconds: 60,
      limit: 16,
      max_attempts: 10,
      base_delay_seconds: 5,
    )
  case outcome {
    Ok(report) if report.claimed > 0 -> Nil
    _ -> process.sleep(interval_milliseconds)
  }
  loop(outbox, provider, worker_id, now, interval_milliseconds)
}

pub fn run_once(
  outbox: Store,
  provider: Provider,
  worker_id worker_id: String,
  now now: Int,
  lease_seconds lease_seconds: Int,
  limit limit: Int,
  max_attempts max_attempts: Int,
  base_delay_seconds base_delay_seconds: Int,
) -> Result(Report, delivery.Error) {
  use jobs <- result.try(outbox.claim(
    provider.kind,
    worker_id,
    now,
    lease_seconds,
    min(16, max(0, limit)),
  ))
  deliver_jobs_concurrently(
    jobs,
    outbox,
    provider,
    worker_id,
    now,
    max_attempts,
    base_delay_seconds,
    Report(
      claimed: list_length(jobs),
      delivered: 0,
      retried: 0,
      dead_lettered: 0,
    ),
  )
}

fn deliver_jobs_concurrently(
  jobs: List(Job),
  outbox: Store,
  provider: Provider,
  worker_id: String,
  now: Int,
  max_attempts: Int,
  base_delay: Int,
  report: Report,
) -> Result(Report, delivery.Error) {
  let results = process.new_subject()
  spawn_deliveries(jobs, provider, results)
  settle_deliveries(
    list_length(jobs),
    results,
    outbox,
    worker_id,
    now,
    max_attempts,
    base_delay,
    report,
    None,
  )
}

fn spawn_deliveries(
  jobs: List(Job),
  provider: Provider,
  results: process.Subject(ProviderResult),
) -> Nil {
  case jobs {
    [] -> Nil
    [job, ..remaining] -> {
      process.spawn(fn() {
        process.send(results, case provider.deliver(job) {
          Ok(_) -> ProviderDelivered(job)
          Error(detail) -> ProviderFailed(job, detail)
        })
      })
      spawn_deliveries(remaining, provider, results)
    }
  }
}

fn settle_deliveries(
  remaining: Int,
  results: process.Subject(ProviderResult),
  outbox: Store,
  worker_id: String,
  now: Int,
  max_attempts: Int,
  base_delay: Int,
  report: Report,
  first_error: Option(delivery.Error),
) -> Result(Report, delivery.Error) {
  case remaining {
    0 ->
      case first_error {
        None -> Ok(report)
        Some(error) -> Error(error)
      }
    _ -> {
      let outcome = process.receive_forever(results)
      let #(report, first_error) = case outcome {
        ProviderDelivered(job) ->
          case outbox.complete(job.id, worker_id) {
            Ok(_) -> #(
              Report(..report, delivered: report.delivered + 1),
              first_error,
            )
            Error(error) -> #(report, option.or(first_error, Some(error)))
          }
        ProviderFailed(job, detail) ->
          case
            outbox.fail(
              job.id,
              worker_id,
              now,
              detail,
              max_attempts,
              base_delay,
            )
          {
            Error(error) -> #(report, option.or(first_error, Some(error)))
            Ok(failed) ->
              case failed.state {
                delivery.DeadLetter -> #(
                  Report(..report, dead_lettered: report.dead_lettered + 1),
                  first_error,
                )
                _ -> #(
                  Report(..report, retried: report.retried + 1),
                  first_error,
                )
              }
          }
      }
      settle_deliveries(
        remaining - 1,
        results,
        outbox,
        worker_id,
        now,
        max_attempts,
        base_delay,
        report,
        first_error,
      )
    }
  }
}

fn list_length(values: List(a)) -> Int {
  case values {
    [] -> 0
    [_, ..rest] -> 1 + list_length(rest)
  }
}

fn max(first: Int, second: Int) -> Int {
  case first > second {
    True -> first
    False -> second
  }
}

fn min(first: Int, second: Int) -> Int {
  case first < second {
    True -> first
    False -> second
  }
}
