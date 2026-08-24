import gleam/option.{type Option}

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

pub type Store {
  Store(
    enqueue: fn(NewJob) -> Result(Job, Error),
    claim: fn(Kind, String, Int, Int, Int) -> Result(List(Job), Error),
    complete: fn(String, String) -> Result(Nil, Error),
    fail: fn(String, String, Int, String, Int, Int) -> Result(Job, Error),
    list: fn(Kind) -> Result(List(Job), Error),
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
  min(base_seconds * power_of_two(attempts - 1), 3600)
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
