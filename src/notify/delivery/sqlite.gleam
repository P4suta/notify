import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import notify/delivery.{type Job, type Store}
import sqlight.{type Connection}

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

const migration = "
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS delivery_outbox (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('webpush', 'mobile_relay')),
  endpoint TEXT NOT NULL,
  payload BLOB NOT NULL,
  message_id TEXT NOT NULL,
  topic_hash TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending', 'leased', 'dead_letter')),
  attempts INTEGER NOT NULL DEFAULT 0,
  available_at INTEGER NOT NULL,
  lease_owner TEXT,
  lease_until INTEGER,
  last_error TEXT,
  created_at INTEGER NOT NULL DEFAULT (unixepoch())
);
CREATE INDEX IF NOT EXISTS delivery_outbox_claim
  ON delivery_outbox(kind, state, available_at, lease_until, created_at);
CREATE INDEX IF NOT EXISTS delivery_outbox_kind_id
  ON delivery_outbox(kind, id);
"

pub fn start(path: String) -> Result(Store, delivery.Error) {
  use connection <- result.try(
    sqlight.open(path) |> result.map_error(map_error),
  )
  case sqlight.exec(migration, connection) {
    Error(error) -> {
      let _ = sqlight.close(connection)
      Error(map_error(error))
    }
    Ok(_) -> start_actor(connection)
  }
}

fn start_actor(connection: Connection) -> Result(Store, delivery.Error) {
  use started <- result.try(
    actor.new(connection)
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(fn(_) {
      delivery.Unavailable("SQLite delivery actor failed to start")
    }),
  )
  let subject = started.data
  Ok(
    delivery.Store(
      enqueue: fn(job) {
        process.call(subject, 10_000, fn(reply) { Enqueue(job, reply) })
      },
      claim: fn(kind, owner, now, lease_seconds, limit) {
        process.call(subject, 10_000, fn(reply) {
          Claim(kind, owner, now, lease_seconds, limit, reply)
        })
      },
      complete: fn(id, owner) {
        process.call(subject, 10_000, fn(reply) { Complete(id, owner, reply) })
      },
      fail: fn(id, owner, now, detail, max_attempts, base_delay) {
        process.call(subject, 10_000, fn(reply) {
          Fail(id, owner, now, detail, max_attempts, base_delay, reply)
        })
      },
      requeue: fn(id, now) {
        process.call(subject, 10_000, fn(reply) { Requeue(id, now, reply) })
      },
      purge: fn(id) {
        process.call(subject, 10_000, fn(reply) { Purge(id, reply) })
      },
      list: fn(kind) {
        process.call(subject, 10_000, fn(reply) { List(kind, reply) })
      },
      page: fn(kind, after, limit) {
        process.call(subject, 10_000, fn(reply) {
          Page(kind, after, limit, reply)
        })
      },
      stats: fn() { process.call(subject, 10_000, Stats) },
      health: fn() { process.call(subject, 10_000, Health) },
    ),
  )
}

fn handle(
  connection: Connection,
  command: Command,
) -> actor.Next(Connection, Command) {
  case command {
    Enqueue(job, reply) -> process.send(reply, enqueue(connection, job))
    Claim(kind, owner, now, lease_seconds, limit, reply) ->
      process.send(
        reply,
        claim(connection, kind, owner, now, lease_seconds, limit),
      )
    Complete(id, owner, reply) ->
      process.send(reply, complete(connection, id, owner))
    Fail(id, owner, now, detail, max_attempts, base_delay, reply) ->
      process.send(
        reply,
        fail(connection, id, owner, now, detail, max_attempts, base_delay),
      )
    Requeue(id, now, reply) -> process.send(reply, requeue(connection, id, now))
    Purge(id, reply) -> process.send(reply, purge(connection, id))
    List(kind, reply) -> process.send(reply, list_jobs(connection, kind))
    Page(kind, after, limit, reply) ->
      process.send(reply, page_jobs(connection, kind, after, limit))
    Stats(reply) -> process.send(reply, stats(connection))
    Health(reply) -> process.send(reply, health(connection))
  }
  actor.continue(connection)
}

fn enqueue(
  connection: Connection,
  new_job: delivery.NewJob,
) -> Result(Job, delivery.Error) {
  let job = delivery.job_from_new(new_job)
  sqlight.query(
    "INSERT INTO delivery_outbox(id, kind, endpoint, payload, message_id, topic_hash, state, attempts, available_at) VALUES (?, ?, ?, ?, ?, ?, 'pending', 0, ?)",
    on: connection,
    with: [
      sqlight.text(job.id),
      sqlight.text(kind_string(job.kind)),
      sqlight.text(job.endpoint),
      sqlight.blob(job.payload),
      sqlight.text(job.message_id),
      sqlight.text(job.topic_hash),
      sqlight.int(job.available_at),
    ],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { job })
  |> result.map_error(map_error)
}

fn claim(
  connection: Connection,
  kind: delivery.Kind,
  owner: String,
  now: Int,
  lease_seconds: Int,
  limit: Int,
) -> Result(List(Job), delivery.Error) {
  transaction(connection, fn() {
    use jobs <- result.try(
      sqlight.query(
        "SELECT id, kind, endpoint, payload, message_id, topic_hash, state, attempts, available_at, lease_owner, lease_until, last_error FROM delivery_outbox WHERE kind = ? AND ((state = 'pending' AND available_at <= ?) OR (state = 'leased' AND lease_until <= ?)) ORDER BY created_at, id LIMIT ?",
        on: connection,
        with: [
          sqlight.text(kind_string(kind)),
          sqlight.int(now),
          sqlight.int(now),
          sqlight.int(max(0, limit)),
        ],
        expecting: job_decoder(),
      )
      |> result.map_error(map_error),
    )
    list.try_map(jobs, fn(job) {
      use _ <- result.try(
        sqlight.query(
          "UPDATE delivery_outbox SET state = 'leased', lease_owner = ?, lease_until = ? WHERE id = ?",
          on: connection,
          with: [
            sqlight.text(owner),
            sqlight.int(now + lease_seconds),
            sqlight.text(job.id),
          ],
          expecting: decode.dynamic,
        )
        |> result.map_error(map_error),
      )
      Ok(
        delivery.Job(
          ..job,
          state: delivery.Leased,
          lease_owner: Some(owner),
          lease_until: Some(now + lease_seconds),
        ),
      )
    })
  })
}

fn complete(
  connection: Connection,
  id: String,
  owner: String,
) -> Result(Nil, delivery.Error) {
  transaction(connection, fn() {
    use job <- result.try(find_job(connection, id))
    case job.state == delivery.Leased && job.lease_owner == Some(owner) {
      False -> Error(delivery.LeaseLost)
      True ->
        sqlight.query(
          "DELETE FROM delivery_outbox WHERE id = ?",
          on: connection,
          with: [sqlight.text(id)],
          expecting: decode.dynamic,
        )
        |> result.map(fn(_) { Nil })
        |> result.map_error(map_error)
    }
  })
}

fn fail(
  connection: Connection,
  id: String,
  owner: String,
  now: Int,
  detail: String,
  max_attempts: Int,
  base_delay: Int,
) -> Result(Job, delivery.Error) {
  transaction(connection, fn() {
    use job <- result.try(find_job(connection, id))
    case job.state == delivery.Leased && job.lease_owner == Some(owner) {
      False -> Error(delivery.LeaseLost)
      True -> {
        let attempts = job.attempts + 1
        let #(state, available_at) = case attempts >= max_attempts {
          True -> #(delivery.DeadLetter, job.available_at)
          False -> #(
            delivery.Pending,
            now + delivery.retry_delay_with_jitter(base_delay, attempts, job.id),
          )
        }
        let updated =
          delivery.Job(
            ..job,
            state:,
            attempts:,
            available_at:,
            lease_owner: None,
            lease_until: None,
            last_error: Some(detail),
          )
        use _ <- result.try(
          sqlight.query(
            "UPDATE delivery_outbox SET state = ?, attempts = ?, available_at = ?, lease_owner = NULL, lease_until = NULL, last_error = ? WHERE id = ?",
            on: connection,
            with: [
              sqlight.text(state_string(state)),
              sqlight.int(attempts),
              sqlight.int(available_at),
              sqlight.text(detail),
              sqlight.text(id),
            ],
            expecting: decode.dynamic,
          )
          |> result.map_error(map_error),
        )
        Ok(updated)
      }
    }
  })
}

fn requeue(
  connection: Connection,
  id: String,
  now: Int,
) -> Result(Job, delivery.Error) {
  transaction(connection, fn() {
    use job <- result.try(find_job(connection, id))
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
        use _ <- result.try(
          sqlight.query(
            "UPDATE delivery_outbox SET state = 'pending', attempts = 0, available_at = ?, lease_owner = NULL, lease_until = NULL WHERE id = ? AND state = 'dead_letter'",
            on: connection,
            with: [sqlight.int(now), sqlight.text(id)],
            expecting: decode.dynamic,
          )
          |> result.map_error(map_error),
        )
        Ok(requeued)
      }
      _ -> Error(delivery.Conflict)
    }
  })
}

fn purge(connection: Connection, id: String) -> Result(Nil, delivery.Error) {
  transaction(connection, fn() {
    use job <- result.try(find_job(connection, id))
    case job.state {
      delivery.DeadLetter ->
        sqlight.query(
          "DELETE FROM delivery_outbox WHERE id = ? AND state = 'dead_letter'",
          on: connection,
          with: [sqlight.text(id)],
          expecting: decode.dynamic,
        )
        |> result.map(fn(_) { Nil })
        |> result.map_error(map_error)
      _ -> Error(delivery.Conflict)
    }
  })
}

fn find_job(connection: Connection, id: String) -> Result(Job, delivery.Error) {
  use jobs <- result.try(
    sqlight.query(
      "SELECT id, kind, endpoint, payload, message_id, topic_hash, state, attempts, available_at, lease_owner, lease_until, last_error FROM delivery_outbox WHERE id = ?",
      on: connection,
      with: [sqlight.text(id)],
      expecting: job_decoder(),
    )
    |> result.map_error(map_error),
  )
  one(jobs)
}

fn list_jobs(
  connection: Connection,
  kind: delivery.Kind,
) -> Result(List(Job), delivery.Error) {
  sqlight.query(
    "SELECT id, kind, endpoint, payload, message_id, topic_hash, state, attempts, available_at, lease_owner, lease_until, last_error FROM delivery_outbox WHERE kind = ? ORDER BY created_at, id",
    on: connection,
    with: [sqlight.text(kind_string(kind))],
    expecting: job_decoder(),
  )
  |> result.map_error(map_error)
}

fn page_jobs(
  connection: Connection,
  kind: Option(delivery.Kind),
  after: Option(String),
  limit: Int,
) -> Result(delivery.Page(delivery.Summary), delivery.Error) {
  use _ <- result.try(valid_page_limit(limit))
  let rows = case kind, after {
    None, None ->
      sqlight.query(
        "SELECT id, kind, message_id, topic_hash, state, attempts, available_at, lease_owner, lease_until, last_error FROM delivery_outbox ORDER BY id LIMIT ?",
        on: connection,
        with: [sqlight.int(limit + 1)],
        expecting: summary_decoder(),
      )
    None, Some(after) ->
      sqlight.query(
        "SELECT id, kind, message_id, topic_hash, state, attempts, available_at, lease_owner, lease_until, last_error FROM delivery_outbox WHERE id > ? ORDER BY id LIMIT ?",
        on: connection,
        with: [sqlight.text(after), sqlight.int(limit + 1)],
        expecting: summary_decoder(),
      )
    Some(kind), None ->
      sqlight.query(
        "SELECT id, kind, message_id, topic_hash, state, attempts, available_at, lease_owner, lease_until, last_error FROM delivery_outbox WHERE kind = ? ORDER BY id LIMIT ?",
        on: connection,
        with: [sqlight.text(kind_string(kind)), sqlight.int(limit + 1)],
        expecting: summary_decoder(),
      )
    Some(kind), Some(after) ->
      sqlight.query(
        "SELECT id, kind, message_id, topic_hash, state, attempts, available_at, lease_owner, lease_until, last_error FROM delivery_outbox WHERE kind = ? AND id > ? ORDER BY id LIMIT ?",
        on: connection,
        with: [
          sqlight.text(kind_string(kind)),
          sqlight.text(after),
          sqlight.int(limit + 1),
        ],
        expecting: summary_decoder(),
      )
  }
  rows
  |> result.map(fn(rows) { bounded_page(rows, limit) })
  |> result.map_error(map_error)
}

fn valid_page_limit(limit: Int) -> Result(Nil, delivery.Error) {
  case limit >= 1 && limit <= 100 {
    True -> Ok(Nil)
    False -> Error(delivery.InvalidPage)
  }
}

fn bounded_page(rows: List(a), limit: Int) -> delivery.Page(a) {
  delivery.Page(
    items: list.take(rows, limit),
    has_more: list.length(rows) > limit,
  )
}

fn stats(connection: Connection) -> Result(delivery.Stats, delivery.Error) {
  use values <- result.try(
    sqlight.query(
      "SELECT COUNT(CASE WHEN kind = 'webpush' AND state = 'pending' THEN 1 END), COUNT(CASE WHEN kind = 'webpush' AND state = 'leased' THEN 1 END), COUNT(CASE WHEN kind = 'webpush' AND state = 'dead_letter' THEN 1 END), COUNT(CASE WHEN kind = 'mobile_relay' AND state = 'pending' THEN 1 END), COUNT(CASE WHEN kind = 'mobile_relay' AND state = 'leased' THEN 1 END), COUNT(CASE WHEN kind = 'mobile_relay' AND state = 'dead_letter' THEN 1 END) FROM delivery_outbox",
      on: connection,
      with: [],
      expecting: stats_decoder(),
    )
    |> result.map_error(map_error),
  )
  case values {
    [statistics] -> Ok(statistics)
    _ ->
      Error(delivery.Unavailable(
        "delivery statistics query returned an invalid row count",
      ))
  }
}

fn stats_decoder() -> decode.Decoder(delivery.Stats) {
  use webpush_pending <- decode.field(0, decode.int)
  use webpush_leased <- decode.field(1, decode.int)
  use webpush_dead_letter <- decode.field(2, decode.int)
  use mobile_relay_pending <- decode.field(3, decode.int)
  use mobile_relay_leased <- decode.field(4, decode.int)
  use mobile_relay_dead_letter <- decode.field(5, decode.int)
  decode.success(delivery.Stats(
    webpush_pending:,
    webpush_leased:,
    webpush_dead_letter:,
    mobile_relay_pending:,
    mobile_relay_leased:,
    mobile_relay_dead_letter:,
  ))
}

fn summary_decoder() -> decode.Decoder(delivery.Summary) {
  use id <- decode.field(0, decode.string)
  use raw_kind <- decode.field(1, decode.string)
  use message_id <- decode.field(2, decode.string)
  use topic_hash <- decode.field(3, decode.string)
  use raw_state <- decode.field(4, decode.string)
  use attempts <- decode.field(5, decode.int)
  use available_at <- decode.field(6, decode.int)
  use lease_owner <- decode.field(7, decode.optional(decode.string))
  use lease_until <- decode.field(8, decode.optional(decode.int))
  use last_error <- decode.field(9, decode.optional(decode.string))
  case parse_kind(raw_kind), parse_state(raw_state) {
    Ok(kind), Ok(state) ->
      decode.success(delivery.Summary(
        id:,
        kind:,
        message_id:,
        topic_hash:,
        state:,
        attempts:,
        available_at:,
        lease_owner:,
        lease_until:,
        last_error:,
      ))
    _, _ ->
      decode.failure(
        delivery.Summary(
          id: "",
          kind: delivery.WebPush,
          message_id: "",
          topic_hash: "",
          state: delivery.DeadLetter,
          attempts: 0,
          available_at: 0,
          lease_owner: None,
          lease_until: None,
          last_error: None,
        ),
        expected: "delivery outbox summary enum",
      )
  }
}

fn job_decoder() -> decode.Decoder(Job) {
  use id <- decode.field(0, decode.string)
  use raw_kind <- decode.field(1, decode.string)
  use endpoint <- decode.field(2, decode.string)
  use payload <- decode.field(3, decode.bit_array)
  use message_id <- decode.field(4, decode.string)
  use topic_hash <- decode.field(5, decode.string)
  use raw_state <- decode.field(6, decode.string)
  use attempts <- decode.field(7, decode.int)
  use available_at <- decode.field(8, decode.int)
  use lease_owner <- decode.field(9, decode.optional(decode.string))
  use lease_until <- decode.field(10, decode.optional(decode.int))
  use last_error <- decode.field(11, decode.optional(decode.string))
  case parse_kind(raw_kind), parse_state(raw_state) {
    Ok(kind), Ok(state) ->
      decode.success(delivery.Job(
        id:,
        kind:,
        endpoint:,
        payload:,
        message_id:,
        topic_hash:,
        state:,
        attempts:,
        available_at:,
        lease_owner:,
        lease_until:,
        last_error:,
      ))
    _, _ ->
      decode.failure(
        delivery.Job(
          id: "",
          kind: delivery.WebPush,
          endpoint: "",
          payload: <<>>,
          message_id: "",
          topic_hash: "",
          state: delivery.DeadLetter,
          attempts: 0,
          available_at: 0,
          lease_owner: None,
          lease_until: None,
          last_error: None,
        ),
        expected: "delivery outbox enum",
      )
  }
}

fn transaction(
  connection: Connection,
  work: fn() -> Result(a, delivery.Error),
) -> Result(a, delivery.Error) {
  use _ <- result.try(
    sqlight.exec("BEGIN IMMEDIATE", connection) |> result.map_error(map_error),
  )
  case work() {
    Error(error) -> {
      let _ = sqlight.exec("ROLLBACK", connection)
      Error(error)
    }
    Ok(value) ->
      case sqlight.exec("COMMIT", connection) {
        Ok(_) -> Ok(value)
        Error(error) -> {
          let _ = sqlight.exec("ROLLBACK", connection)
          Error(map_error(error))
        }
      }
  }
}

fn health(connection: Connection) -> Result(Nil, delivery.Error) {
  sqlight.query("SELECT 1", on: connection, with: [], expecting: decode.dynamic)
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn one(jobs: List(Job)) -> Result(Job, delivery.Error) {
  case jobs {
    [job] -> Ok(job)
    [] -> Error(delivery.NotFound)
    _ -> Error(delivery.Unavailable("duplicate delivery job"))
  }
}

fn kind_string(kind: delivery.Kind) -> String {
  case kind {
    delivery.WebPush -> "webpush"
    delivery.MobileRelay -> "mobile_relay"
  }
}

fn parse_kind(value: String) -> Result(delivery.Kind, Nil) {
  case value {
    "webpush" -> Ok(delivery.WebPush)
    "mobile_relay" -> Ok(delivery.MobileRelay)
    _ -> Error(Nil)
  }
}

fn state_string(state: delivery.State) -> String {
  case state {
    delivery.Pending -> "pending"
    delivery.Leased -> "leased"
    delivery.DeadLetter -> "dead_letter"
  }
}

fn parse_state(value: String) -> Result(delivery.State, Nil) {
  case value {
    "pending" -> Ok(delivery.Pending)
    "leased" -> Ok(delivery.Leased)
    "dead_letter" -> Ok(delivery.DeadLetter)
    _ -> Error(Nil)
  }
}

fn max(first: Int, second: Int) -> Int {
  case first > second {
    True -> first
    False -> second
  }
}

fn map_error(error: sqlight.Error) -> delivery.Error {
  let sqlight.SqlightError(code:, message:, ..) = error
  case code {
    sqlight.Constraint | sqlight.ConstraintUnique -> delivery.Conflict
    _ -> delivery.Unavailable(message)
  }
}
