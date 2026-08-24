import gleam/int
import gleam/list
import gleam/option.{type Option}
import gleam/string

pub type Kind {
  WebPush
  MobileRelay
}

pub type State {
  Pending
  Leased
  DeadLetter
}

pub type NewJob {
  NewJob(
    id: String,
    kind: Kind,
    endpoint: String,
    payload: BitArray,
    message_id: String,
    topic_hash: String,
    available_at: Int,
  )
}

pub type Job {
  Job(
    id: String,
    kind: Kind,
    endpoint: String,
    payload: BitArray,
    message_id: String,
    topic_hash: String,
    state: State,
    attempts: Int,
    available_at: Int,
    lease_owner: Option(String),
    lease_until: Option(Int),
    last_error: Option(String),
  )
}

pub type Error {
  NotFound
  Conflict
  LeaseLost
  Unavailable(String)
}

pub type Stats {
  Stats(
    webpush_pending: Int,
    webpush_leased: Int,
    webpush_dead_letter: Int,
    mobile_relay_pending: Int,
    mobile_relay_leased: Int,
    mobile_relay_dead_letter: Int,
  )
}

pub type Store {
  Store(
    enqueue: fn(NewJob) -> Result(Job, Error),
    claim: fn(Kind, String, Int, Int, Int) -> Result(List(Job), Error),
    complete: fn(String, String) -> Result(Nil, Error),
    fail: fn(String, String, Int, String, Int, Int) -> Result(Job, Error),
    requeue: fn(String, Int) -> Result(Job, Error),
    purge: fn(String) -> Result(Nil, Error),
    list: fn(Kind) -> Result(List(Job), Error),
    stats: fn() -> Result(Stats, Error),
    health: fn() -> Result(Nil, Error),
  )
}

pub fn job_from_new(job: NewJob) -> Job {
  Job(
    id: job.id,
    kind: job.kind,
    endpoint: job.endpoint,
    payload: job.payload,
    message_id: job.message_id,
    topic_hash: job.topic_hash,
    state: Pending,
    attempts: 0,
    available_at: job.available_at,
    lease_owner: option.None,
    lease_until: option.None,
    last_error: option.None,
  )
}

pub fn retry_delay(base_seconds: Int, attempts: Int) -> Int {
  let base = int.max(1, base_seconds)
  let exponent = attempts - 1 |> int.max(0) |> int.min(12)
  min(base * power_of_two(exponent), 3600)
}

/// Equal jitter keeps retries from synchronising across nodes while retaining
/// a lower bound of half the exponential delay. The stable seed makes the
/// persisted schedule reproducible after a transaction retry.
pub fn retry_delay_with_jitter(
  base_seconds: Int,
  attempts: Int,
  seed: String,
) -> Int {
  let ceiling = retry_delay(base_seconds, attempts)
  let assert Ok(half) = int.floor_divide(ceiling, 2)
  let floor = int.max(1, half)
  let span = ceiling - floor + 1
  let hash =
    string.to_utf_codepoints(seed)
    |> list.fold(attempts, fn(accumulator, codepoint) {
      let assert Ok(reduced) =
        int.modulo(
          accumulator * 33 + string.utf_codepoint_to_int(codepoint),
          2_147_483_647,
        )
      reduced
    })
  let assert Ok(offset) = int.modulo(hash, span)
  floor + offset
}

pub fn empty_stats() -> Stats {
  Stats(0, 0, 0, 0, 0, 0)
}

pub fn count(jobs: List(Job)) -> Stats {
  jobs
  |> list.fold(empty_stats(), fn(statistics, job) {
    case job.kind, job.state {
      WebPush, Pending ->
        Stats(..statistics, webpush_pending: statistics.webpush_pending + 1)
      WebPush, Leased ->
        Stats(..statistics, webpush_leased: statistics.webpush_leased + 1)
      WebPush, DeadLetter ->
        Stats(
          ..statistics,
          webpush_dead_letter: statistics.webpush_dead_letter + 1,
        )
      MobileRelay, Pending ->
        Stats(
          ..statistics,
          mobile_relay_pending: statistics.mobile_relay_pending + 1,
        )
      MobileRelay, Leased ->
        Stats(
          ..statistics,
          mobile_relay_leased: statistics.mobile_relay_leased + 1,
        )
      MobileRelay, DeadLetter ->
        Stats(
          ..statistics,
          mobile_relay_dead_letter: statistics.mobile_relay_dead_letter + 1,
        )
    }
  })
}

fn power_of_two(exponent: Int) -> Int {
  case exponent <= 0 {
    True -> 1
    False -> 2 * power_of_two(exponent - 1)
  }
}

fn min(first: Int, second: Int) -> Int {
  case first < second {
    True -> first
    False -> second
  }
}
