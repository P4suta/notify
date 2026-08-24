import gleam/erlang/process.{type Pid}
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
  let _ =
    run_once(
      outbox,
      provider,
      worker_id:,
      now: now(),
      lease_seconds: 60,
      limit: 100,
      max_attempts: 10,
      base_delay_seconds: 5,
    )
  process.sleep(interval_milliseconds)
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
    limit,
  ))
  deliver_jobs(
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

fn deliver_jobs(
  jobs: List(Job),
  outbox: Store,
  provider: Provider,
  worker_id: String,
  now: Int,
  max_attempts: Int,
  base_delay: Int,
  report: Report,
) -> Result(Report, delivery.Error) {
  case jobs {
    [] -> Ok(report)
    [job, ..rest] ->
      case provider.deliver(job) {
        Ok(_) -> {
          use _ <- result.try(outbox.complete(job.id, worker_id))
          deliver_jobs(
            rest,
            outbox,
            provider,
            worker_id,
            now,
            max_attempts,
            base_delay,
            Report(..report, delivered: report.delivered + 1),
          )
        }
        Error(detail) -> {
          use failed <- result.try(outbox.fail(
            job.id,
            worker_id,
            now,
            detail,
            max_attempts,
            base_delay,
          ))
          let updated = case failed.state {
            delivery.DeadLetter ->
              Report(..report, dead_lettered: report.dead_lettered + 1)
            _ -> Report(..report, retried: report.retried + 1)
          }
          deliver_jobs(
            rest,
            outbox,
            provider,
            worker_id,
            now,
            max_attempts,
            base_delay,
            updated,
          )
        }
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
