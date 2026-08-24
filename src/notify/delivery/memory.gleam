import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/otp/actor
import gleam/result
import gleam/string
import notify/delivery.{type Job, type Store}

type Command {
  Enqueue(delivery.NewJob, Subject(Result(Job, delivery.Error)))
  Claim(
    delivery.Kind,
    String,
    Int,
    Int,
    Int,
    Subject(Result(List(Job), delivery.Error)),
  )
  Complete(String, String, Subject(Result(Nil, delivery.Error)))
  Fail(
    String,
    String,
    Int,
    String,
    Int,
    Int,
    Subject(Result(Job, delivery.Error)),
  )
  Requeue(String, Int, Subject(Result(Job, delivery.Error)))
  Purge(String, Subject(Result(Nil, delivery.Error)))
  List(delivery.Kind, Subject(Result(List(Job), delivery.Error)))
  Page(
    Option(delivery.Kind),
    Option(String),
    Int,
    Subject(Result(delivery.Page(delivery.Summary), delivery.Error)),
  )
  Stats(Subject(Result(delivery.Stats, delivery.Error)))
  Health(Subject(Result(Nil, delivery.Error)))
}

pub fn start() -> Result(Store, actor.StartError) {
  use started <- result.try(
    actor.new([])
    |> actor.on_message(handle)
    |> actor.start,
  )
  let subject = started.data
  Ok(
    delivery.Store(
      enqueue: fn(job) {
        process.call(subject, 5000, fn(reply) { Enqueue(job, reply) })
      },
      claim: fn(kind, owner, now, lease_seconds, limit) {
        process.call(subject, 5000, fn(reply) {
          Claim(kind, owner, now, lease_seconds, limit, reply)
        })
      },
      complete: fn(id, owner) {
        process.call(subject, 5000, fn(reply) { Complete(id, owner, reply) })
      },
      fail: fn(id, owner, now, detail, max_attempts, base_delay) {
        process.call(subject, 5000, fn(reply) {
          Fail(id, owner, now, detail, max_attempts, base_delay, reply)
        })
      },
      requeue: fn(id, now) {
        process.call(subject, 5000, fn(reply) { Requeue(id, now, reply) })
      },
      purge: fn(id) {
        process.call(subject, 5000, fn(reply) { Purge(id, reply) })
      },
      list: fn(kind) {
        process.call(subject, 5000, fn(reply) { List(kind, reply) })
      },
      page: fn(kind, after, limit) {
        process.call(subject, 5000, fn(reply) {
          Page(kind, after, limit, reply)
        })
      },
      stats: fn() { process.call(subject, 5000, Stats) },
      health: fn() { process.call(subject, 5000, Health) },
    ),
  )
}

fn handle(jobs: List(Job), command: Command) -> actor.Next(List(Job), Command) {
  case command {
    Enqueue(new_job, reply) -> {
      case list.any(jobs, fn(job) { job.id == new_job.id }) {
        True -> {
          process.send(reply, Error(delivery.Conflict))
          actor.continue(jobs)
        }
        False -> {
          let job = delivery.job_from_new(new_job)
          process.send(reply, Ok(job))
          actor.continue(list.append(jobs, [job]))
        }
      }
    }
    Claim(kind, owner, now, lease_seconds, limit, reply) -> {
      let selected =
        jobs
        |> list.filter(fn(job) { claimable(job, kind, now) })
        |> list.take(limit)
        |> list.map(fn(job) {
          delivery.Job(
            ..job,
            state: delivery.Leased,
            lease_owner: Some(owner),
            lease_until: Some(now + lease_seconds),
          )
        })
      let updated =
        list.map(jobs, fn(job) {
          case list.find(selected, fn(selected) { selected.id == job.id }) {
            Ok(selected) -> selected
            Error(_) -> job
          }
        })
      process.send(reply, Ok(selected))
      actor.continue(updated)
    }
    Complete(id, owner, reply) -> {
      case list.find(jobs, fn(job) { job.id == id }) {
        Error(_) -> {
          process.send(reply, Error(delivery.NotFound))
          actor.continue(jobs)
        }
        Ok(job) ->
          case job.state == delivery.Leased && job.lease_owner == Some(owner) {
            False -> {
              process.send(reply, Error(delivery.LeaseLost))
              actor.continue(jobs)
            }
            True -> {
              process.send(reply, Ok(Nil))
              actor.continue(list.filter(jobs, fn(job) { job.id != id }))
            }
          }
      }
    }
    Fail(id, owner, now, detail, max_attempts, base_delay, reply) -> {
      case list.find(jobs, fn(job) { job.id == id }) {
        Error(_) -> {
          process.send(reply, Error(delivery.NotFound))
          actor.continue(jobs)
        }
        Ok(job) ->
          case job.state == delivery.Leased && job.lease_owner == Some(owner) {
            False -> {
              process.send(reply, Error(delivery.LeaseLost))
              actor.continue(jobs)
            }
            True -> {
              let attempts = job.attempts + 1
              let failed = case attempts >= max_attempts {
                True ->
                  delivery.Job(
                    ..job,
                    state: delivery.DeadLetter,
                    attempts:,
                    lease_owner: None,
                    lease_until: None,
                    last_error: Some(detail),
                  )
                False ->
                  delivery.Job(
                    ..job,
                    state: delivery.Pending,
                    attempts:,
                    available_at: now
                      + delivery.retry_delay_with_jitter(
                        base_delay,
                        attempts,
                        job.id,
                      ),
                    lease_owner: None,
                    lease_until: None,
                    last_error: Some(detail),
                  )
              }
              let updated =
                list.map(jobs, fn(current) {
                  case current.id == id {
                    True -> failed
                    False -> current
                  }
                })
              process.send(reply, Ok(failed))
              actor.continue(updated)
            }
          }
      }
    }
    Requeue(id, now, reply) -> {
      case list.find(jobs, fn(job) { job.id == id }) {
        Error(_) -> {
          process.send(reply, Error(delivery.NotFound))
          actor.continue(jobs)
        }
        Ok(job) ->
          case job.state {
            delivery.DeadLetter -> {
              let requeued =
                delivery.Job(
                  ..job,
                  state: delivery.Pending,
                  attempts: 0,
                  available_at: now,
                  lease_owner: None,
                  lease_until: None,
                )
              process.send(reply, Ok(requeued))
              actor.continue(
                list.map(jobs, fn(current) {
                  case current.id == id {
                    True -> requeued
                    False -> current
                  }
                }),
              )
            }
            _ -> {
              process.send(reply, Error(delivery.Conflict))
              actor.continue(jobs)
            }
          }
      }
    }
    Purge(id, reply) -> {
      case list.find(jobs, fn(job) { job.id == id }) {
        Error(_) -> {
          process.send(reply, Error(delivery.NotFound))
          actor.continue(jobs)
        }
        Ok(job) ->
          case job.state {
            delivery.DeadLetter -> {
              process.send(reply, Ok(Nil))
              actor.continue(list.filter(jobs, fn(job) { job.id != id }))
            }
            _ -> {
              process.send(reply, Error(delivery.Conflict))
              actor.continue(jobs)
            }
          }
      }
    }
    List(kind, reply) -> {
      process.send(reply, Ok(list.filter(jobs, fn(job) { job.kind == kind })))
      actor.continue(jobs)
    }
    Page(kind, after, limit, reply) -> {
      process.send(reply, page_jobs(jobs, kind, after, limit))
      actor.continue(jobs)
    }
    Stats(reply) -> {
      process.send(reply, Ok(delivery.count(jobs)))
      actor.continue(jobs)
    }
    Health(reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(jobs)
    }
  }
}

fn page_jobs(
  jobs: List(Job),
  kind: Option(delivery.Kind),
  after: Option(String),
  limit: Int,
) -> Result(delivery.Page(delivery.Summary), delivery.Error) {
  case limit >= 1 && limit <= 100 {
    False -> Error(delivery.InvalidPage)
    True -> {
      let selected =
        jobs
        |> list.filter(fn(job) {
          let matches_kind = case kind {
            None -> True
            Some(kind) -> job.kind == kind
          }
          let follows_cursor = case after {
            None -> True
            Some(after) -> string.compare(job.id, after) == order.Gt
          }
          matches_kind && follows_cursor
        })
        |> list.sort(by: fn(left, right) { string.compare(left.id, right.id) })
      Ok(delivery.Page(
        items: selected |> list.take(limit) |> list.map(delivery.summary),
        has_more: list.length(selected) > limit,
      ))
    }
  }
}

fn claimable(job: Job, kind: delivery.Kind, now: Int) -> Bool {
  job.kind == kind
  && case job.state, job.lease_until {
    delivery.Pending, _ -> job.available_at <= now
    delivery.Leased, Some(until) -> until <= now
    _, _ -> False
  }
}
