import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import notify/delivery.{type Job, type Store}
import postgleam
import postgleam/config.{type Config}
import postgleam/decode
import postgleam/error as pg_error

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

type State {
  State(config: Config, connection: postgleam.Connection, reconnect: Bool)
}

const migration = "
CREATE TABLE IF NOT EXISTS notify_delivery_outbox (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('webpush', 'mobile_relay')),
  endpoint TEXT NOT NULL,
  payload BYTEA NOT NULL,
  message_id TEXT NOT NULL,
  topic_hash TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending', 'leased', 'dead_letter')),
  attempts BIGINT NOT NULL DEFAULT 0,
  available_at BIGINT NOT NULL,
  lease_owner TEXT,
  lease_until BIGINT,
  last_error TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS notify_delivery_outbox_claim
  ON notify_delivery_outbox(kind, state, available_at, lease_until, created_at);
CREATE INDEX IF NOT EXISTS notify_delivery_outbox_kind_id
  ON notify_delivery_outbox(kind, id);
"

const endpoint_lock_salt = 7_413_706_850

const claim_index_lock = 7_413_706_851

pub fn start(config: Config) -> Result(Store, delivery.Error) {
  use connection <- result.try(
    postgleam.connect(config) |> result.map_error(map_error),
  )
  case migrate(connection) {
    Error(error) -> {
      postgleam.disconnect(connection)
      Error(error)
    }
    Ok(_) -> start_actor(config, connection)
  }
}

fn migrate(connection: postgleam.Connection) -> Result(Nil, delivery.Error) {
  use _ <- result.try(
    postgleam.transaction(connection, fn(tx) {
      use _ <- result.try(
        postgleam.query(tx, "SELECT pg_advisory_xact_lock($1::bigint)", [
          postgleam.int(7_413_706_845),
        ]),
      )
      use _ <- result.try(postgleam.simple_query(tx, migration))
      Ok(Nil)
    })
    |> result.map_error(map_error),
  )
  create_claim_indexes(connection)
}

fn create_claim_indexes(
  connection: postgleam.Connection,
) -> Result(Nil, delivery.Error) {
  use _ <- result.try(
    postgleam.query(connection, "SELECT pg_advisory_lock($1::bigint)", [
      postgleam.int(claim_index_lock),
    ])
    |> result.map_error(map_error),
  )
  let created = case
    postgleam.simple_query(
      connection,
      "CREATE INDEX CONCURRENTLY IF NOT EXISTS notify_delivery_outbox_claim_pending ON notify_delivery_outbox(kind, endpoint, available_at, created_at, id) WHERE state = 'pending'",
    )
  {
    Error(error) -> Error(error)
    Ok(_) ->
      postgleam.simple_query(
        connection,
        "CREATE INDEX CONCURRENTLY IF NOT EXISTS notify_delivery_outbox_claim_leased ON notify_delivery_outbox(kind, endpoint, lease_until, created_at, id) WHERE state = 'leased'",
      )
  }
  let unlocked =
    postgleam.query(connection, "SELECT pg_advisory_unlock($1::bigint)", [
      postgleam.int(claim_index_lock),
    ])
  case created, unlocked {
    Error(error), _ | _, Error(error) -> Error(map_error(error))
    Ok(_), Ok(_) -> Ok(Nil)
  }
}

fn start_actor(
  config: Config,
  connection: postgleam.Connection,
) -> Result(Store, delivery.Error) {
  use started <- result.try(
    actor.new(State(config:, connection:, reconnect: False))
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(fn(_) {
      delivery.Unavailable("PostgreSQL delivery actor failed to start")
    }),
  )
  let subject = started.data
  Ok(
    delivery.Store(
      enqueue: fn(job) {
        process.call(subject, 30_000, fn(reply) { Enqueue(job, reply) })
      },
      claim: fn(kind, owner, now, lease_seconds, limit) {
        process.call(subject, 30_000, fn(reply) {
          Claim(kind, owner, now, lease_seconds, limit, reply)
        })
      },
      complete: fn(id, owner) {
        process.call(subject, 30_000, fn(reply) { Complete(id, owner, reply) })
      },
      fail: fn(id, owner, now, detail, max_attempts, base_delay) {
        process.call(subject, 30_000, fn(reply) {
          Fail(id, owner, now, detail, max_attempts, base_delay, reply)
        })
      },
      requeue: fn(id, now) {
        process.call(subject, 30_000, fn(reply) { Requeue(id, now, reply) })
      },
      purge: fn(id) {
        process.call(subject, 30_000, fn(reply) { Purge(id, reply) })
      },
      list: fn(kind) {
        process.call(subject, 30_000, fn(reply) { List(kind, reply) })
      },
      page: fn(kind, after, limit) {
        process.call(subject, 30_000, fn(reply) {
          Page(kind, after, limit, reply)
        })
      },
      stats: fn() { process.call(subject, 30_000, Stats) },
      health: fn() { process.call(subject, 30_000, Health) },
    ),
  )
}

fn handle(state: State, command: Command) -> actor.Next(State, Command) {
  case command {
    Enqueue(job, reply) ->
      respond(state, reply, fn(connection) { enqueue(connection, job) })
    Claim(kind, owner, now, lease_seconds, limit, reply) ->
      respond(state, reply, fn(connection) {
        claim(connection, kind, owner, now, lease_seconds, limit)
      })
    Complete(id, owner, reply) ->
      respond(state, reply, fn(connection) { complete(connection, id, owner) })
    Fail(id, owner, now, detail, max_attempts, base_delay, reply) ->
      respond(state, reply, fn(connection) {
        fail(connection, id, owner, now, detail, max_attempts, base_delay)
      })
    Requeue(id, now, reply) ->
      respond(state, reply, fn(connection) { requeue(connection, id, now) })
    Purge(id, reply) ->
      respond(state, reply, fn(connection) { purge(connection, id) })
    List(kind, reply) ->
      respond(state, reply, fn(connection) { list_jobs(connection, kind) })
    Page(kind, after, limit, reply) ->
      respond(state, reply, fn(connection) {
        page_jobs(connection, kind, after, limit)
      })
    Stats(reply) -> respond(state, reply, stats)
    Health(reply) -> respond(state, reply, health)
  }
}

fn respond(
  state: State,
  reply: Subject(Result(value, delivery.Error)),
  operation: fn(postgleam.Connection) -> Result(value, delivery.Error),
) -> actor.Next(State, Command) {
  let #(next, outcome) = run(state, operation)
  process.send(reply, outcome)
  actor.continue(next)
}

fn run(
  state: State,
  operation: fn(postgleam.Connection) -> Result(value, delivery.Error),
) -> #(State, Result(value, delivery.Error)) {
  case ready_connection(state) {
    Error(error) -> #(state, Error(error))
    Ok(ready) -> {
      let outcome = operation(ready.connection)
      case outcome {
        Error(delivery.Unavailable(_)) -> #(
          State(..ready, reconnect: True),
          outcome,
        )
        _ -> #(ready, outcome)
      }
    }
  }
}

fn ready_connection(state: State) -> Result(State, delivery.Error) {
  case state.reconnect {
    False -> Ok(state)
    True ->
      case postgleam.connect(state.config) {
        Error(error) -> Error(map_error(error))
        Ok(connection) -> {
          postgleam.disconnect(state.connection)
          Ok(State(..state, connection:, reconnect: False))
        }
      }
  }
}

fn enqueue(
  connection: postgleam.Connection,
  new_job: delivery.NewJob,
) -> Result(Job, delivery.Error) {
  let job = delivery.job_from_new(new_job)
  postgleam.query(
    connection,
    "INSERT INTO notify_delivery_outbox(id, kind, endpoint, payload, message_id, topic_hash, state, attempts, available_at) VALUES ($1, $2, $3, $4, $5, $6, 'pending', 0, $7)",
    [
      postgleam.text(job.id),
      postgleam.text(kind_string(job.kind)),
      postgleam.text(job.endpoint),
      postgleam.bytea(job.payload),
      postgleam.text(job.message_id),
      postgleam.text(job.topic_hash),
      postgleam.int(job.available_at),
    ],
  )
  |> result.map(fn(_) { job })
  |> result.map_error(map_error)
}

fn claim(
  connection: postgleam.Connection,
  kind: delivery.Kind,
  owner: String,
  now: Int,
  lease_seconds: Int,
  limit: Int,
) -> Result(List(Job), delivery.Error) {
  postgleam.transaction(connection, fn(tx) {
    postgleam.query_with(
      tx,
      "WITH heads AS MATERIALIZED (SELECT jobs.id, jobs.endpoint, jobs.created_at FROM notify_delivery_outbox AS jobs WHERE jobs.kind = $1 AND jobs.state != 'dead_letter' AND NOT EXISTS (SELECT 1 FROM notify_delivery_outbox AS earlier WHERE earlier.kind = jobs.kind AND earlier.endpoint = jobs.endpoint AND earlier.state != 'dead_letter' AND (earlier.created_at < jobs.created_at OR (earlier.created_at = jobs.created_at AND earlier.id < jobs.id))) AND ((jobs.state = 'pending' AND jobs.available_at <= $2) OR (jobs.state = 'leased' AND jobs.lease_until <= $2)) ORDER BY jobs.created_at, jobs.id FOR UPDATE OF jobs SKIP LOCKED LIMIT $3), locked AS MATERIALIZED (SELECT heads.id FROM heads WHERE pg_try_advisory_xact_lock(hashtextextended(heads.endpoint, $6))) UPDATE notify_delivery_outbox AS jobs SET state = 'leased', lease_owner = $4, lease_until = $5 FROM locked WHERE jobs.id = locked.id RETURNING jobs.id, jobs.kind, jobs.endpoint, jobs.payload, jobs.message_id, jobs.topic_hash, jobs.state, jobs.attempts, jobs.available_at, jobs.lease_owner, jobs.lease_until, jobs.last_error",
      [
        postgleam.text(kind_string(kind)),
        postgleam.int(now),
        postgleam.int(min(16, max(0, limit))),
        postgleam.text(owner),
        postgleam.int(now + lease_seconds),
        postgleam.int(endpoint_lock_salt),
      ],
      job_decoder(),
    )
  })
  |> result.map(fn(response) { response.rows })
  |> result.map_error(map_error)
}

fn complete(
  connection: postgleam.Connection,
  id: String,
  owner: String,
) -> Result(Nil, delivery.Error) {
  postgleam.transaction(connection, fn(tx) {
    use job <- result.try(
      find_job(tx, id, True) |> result.map_error(to_pg_error),
    )
    case job.state == delivery.Leased && job.lease_owner == Some(owner) {
      False -> Error(postgleam.query_error("delivery lease lost"))
      True -> {
        use _ <- result.try(
          postgleam.query(
            tx,
            "DELETE FROM notify_delivery_outbox WHERE id = $1",
            [postgleam.text(id)],
          ),
        )
        Ok(Nil)
      }
    }
  })
  |> result.map_error(fn(error) {
    case error {
      pg_error.ConnectionError("delivery not found") -> delivery.NotFound
      pg_error.ConnectionError("delivery lease lost") -> delivery.LeaseLost
      other -> map_error(other)
    }
  })
}

fn fail(
  connection: postgleam.Connection,
  id: String,
  owner: String,
  now: Int,
  detail: String,
  max_attempts: Int,
  base_delay: Int,
) -> Result(Job, delivery.Error) {
  postgleam.transaction(connection, fn(tx) {
    use job <- result.try(
      find_job(tx, id, True) |> result.map_error(to_pg_error),
    )
    case job.state == delivery.Leased && job.lease_owner == Some(owner) {
      False -> Error(postgleam.query_error("delivery lease lost"))
      True -> {
        let attempts = job.attempts + 1
        let #(state, available_at) = case attempts >= max_attempts {
          True -> #(delivery.DeadLetter, job.available_at)
          False -> #(
            delivery.Pending,
            now + delivery.retry_delay_with_jitter(base_delay, attempts, job.id),
          )
        }
        use response <- result.try(postgleam.query_with(
          tx,
          "UPDATE notify_delivery_outbox SET state = $1, attempts = $2, available_at = $3, lease_owner = NULL, lease_until = NULL, last_error = $4 WHERE id = $5 RETURNING id, kind, endpoint, payload, message_id, topic_hash, state, attempts, available_at, lease_owner, lease_until, last_error",
          [
            postgleam.text(state_string(state)),
            postgleam.int(attempts),
            postgleam.int(available_at),
            postgleam.text(detail),
            postgleam.text(id),
          ],
          job_decoder(),
        ))
        case response.rows {
          [updated] -> Ok(updated)
          _ -> Error(postgleam.query_error("delivery update failed"))
        }
      }
    }
  })
  |> result.map_error(fn(error) {
    case error {
      pg_error.ConnectionError("delivery not found") -> delivery.NotFound
      pg_error.ConnectionError("delivery lease lost") -> delivery.LeaseLost
      other -> map_error(other)
    }
  })
}

fn requeue(
  connection: postgleam.Connection,
  id: String,
  now: Int,
) -> Result(Job, delivery.Error) {
  postgleam.transaction(connection, fn(tx) {
    use job <- result.try(
      find_job(tx, id, True) |> result.map_error(to_pg_error),
    )
    case job.state {
      delivery.DeadLetter -> {
        use response <- result.try(postgleam.query_with(
          tx,
          "UPDATE notify_delivery_outbox SET state = 'pending', attempts = 0, available_at = $1, lease_owner = NULL, lease_until = NULL WHERE id = $2 AND state = 'dead_letter' RETURNING id, kind, endpoint, payload, message_id, topic_hash, state, attempts, available_at, lease_owner, lease_until, last_error",
          [postgleam.int(now), postgleam.text(id)],
          job_decoder(),
        ))
        case response.rows {
          [requeued] -> Ok(requeued)
          _ -> Error(postgleam.query_error("delivery update failed"))
        }
      }
      _ -> Error(postgleam.query_error("delivery conflict"))
    }
  })
  |> result.map_error(map_transaction_error)
}

fn purge(
  connection: postgleam.Connection,
  id: String,
) -> Result(Nil, delivery.Error) {
  postgleam.transaction(connection, fn(tx) {
    use job <- result.try(
      find_job(tx, id, True) |> result.map_error(to_pg_error),
    )
    case job.state {
      delivery.DeadLetter -> {
        use _ <- result.try(
          postgleam.query(
            tx,
            "DELETE FROM notify_delivery_outbox WHERE id = $1 AND state = 'dead_letter'",
            [postgleam.text(id)],
          ),
        )
        Ok(Nil)
      }
      _ -> Error(postgleam.query_error("delivery conflict"))
    }
  })
  |> result.map_error(map_transaction_error)
}

fn find_job(
  connection: postgleam.Connection,
  id: String,
  lock: Bool,
) -> Result(Job, delivery.Error) {
  let suffix = case lock {
    True -> " FOR UPDATE"
    False -> ""
  }
  use response <- result.try(
    postgleam.query_with(
      connection,
      "SELECT id, kind, endpoint, payload, message_id, topic_hash, state, attempts, available_at, lease_owner, lease_until, last_error FROM notify_delivery_outbox WHERE id = $1"
        <> suffix,
      [postgleam.text(id)],
      job_decoder(),
    )
    |> result.map_error(map_error),
  )
  case response.rows {
    [job] -> Ok(job)
    [] -> Error(delivery.NotFound)
    _ -> Error(delivery.Unavailable("duplicate delivery job"))
  }
}

fn list_jobs(
  connection: postgleam.Connection,
  kind: delivery.Kind,
) -> Result(List(Job), delivery.Error) {
  postgleam.query_with(
    connection,
    "SELECT id, kind, endpoint, payload, message_id, topic_hash, state, attempts, available_at, lease_owner, lease_until, last_error FROM notify_delivery_outbox WHERE kind = $1 ORDER BY created_at, id",
    [postgleam.text(kind_string(kind))],
    job_decoder(),
  )
  |> result.map(fn(response) { response.rows })
  |> result.map_error(map_error)
}

fn page_jobs(
  connection: postgleam.Connection,
  kind: Option(delivery.Kind),
  after: Option(String),
  limit: Int,
) -> Result(delivery.Page(delivery.Summary), delivery.Error) {
  use _ <- result.try(valid_page_limit(limit))
  let rows = case kind, after {
    None, None ->
      postgleam.query_with(
        connection,
        "SELECT id, kind, message_id, topic_hash, state, attempts, available_at, lease_owner, lease_until, last_error FROM notify_delivery_outbox ORDER BY id LIMIT $1",
        [postgleam.int(limit + 1)],
        summary_decoder(),
      )
    None, Some(after) ->
      postgleam.query_with(
        connection,
        "SELECT id, kind, message_id, topic_hash, state, attempts, available_at, lease_owner, lease_until, last_error FROM notify_delivery_outbox WHERE id > $1 ORDER BY id LIMIT $2",
        [postgleam.text(after), postgleam.int(limit + 1)],
        summary_decoder(),
      )
    Some(kind), None ->
      postgleam.query_with(
        connection,
        "SELECT id, kind, message_id, topic_hash, state, attempts, available_at, lease_owner, lease_until, last_error FROM notify_delivery_outbox WHERE kind = $1 ORDER BY id LIMIT $2",
        [postgleam.text(kind_string(kind)), postgleam.int(limit + 1)],
        summary_decoder(),
      )
    Some(kind), Some(after) ->
      postgleam.query_with(
        connection,
        "SELECT id, kind, message_id, topic_hash, state, attempts, available_at, lease_owner, lease_until, last_error FROM notify_delivery_outbox WHERE kind = $1 AND id > $2 ORDER BY id LIMIT $3",
        [
          postgleam.text(kind_string(kind)),
          postgleam.text(after),
          postgleam.int(limit + 1),
        ],
        summary_decoder(),
      )
  }
  rows
  |> result.map(fn(response) { bounded_page(response.rows, limit) })
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

fn stats(
  connection: postgleam.Connection,
) -> Result(delivery.Stats, delivery.Error) {
  use response <- result.try(
    postgleam.query_with(
      connection,
      "SELECT COUNT(*) FILTER (WHERE kind = 'webpush' AND state = 'pending'), COUNT(*) FILTER (WHERE kind = 'webpush' AND state = 'leased'), COUNT(*) FILTER (WHERE kind = 'webpush' AND state = 'dead_letter'), COUNT(*) FILTER (WHERE kind = 'mobile_relay' AND state = 'pending'), COUNT(*) FILTER (WHERE kind = 'mobile_relay' AND state = 'leased'), COUNT(*) FILTER (WHERE kind = 'mobile_relay' AND state = 'dead_letter') FROM notify_delivery_outbox",
      [],
      stats_decoder(),
    )
    |> result.map_error(map_error),
  )
  case response.rows {
    [statistics] -> Ok(statistics)
    _ ->
      Error(delivery.Unavailable(
        "delivery statistics query returned an invalid row count",
      ))
  }
}

fn stats_decoder() -> decode.RowDecoder(delivery.Stats) {
  use webpush_pending <- decode.element(0, decode.int)
  use webpush_leased <- decode.element(1, decode.int)
  use webpush_dead_letter <- decode.element(2, decode.int)
  use mobile_relay_pending <- decode.element(3, decode.int)
  use mobile_relay_leased <- decode.element(4, decode.int)
  use mobile_relay_dead_letter <- decode.element(5, decode.int)
  decode.success(delivery.Stats(
    webpush_pending:,
    webpush_leased:,
    webpush_dead_letter:,
    mobile_relay_pending:,
    mobile_relay_leased:,
    mobile_relay_dead_letter:,
  ))
}

fn summary_decoder() -> decode.RowDecoder(delivery.Summary) {
  use id <- decode.element(0, decode.text)
  use kind <- decode.element(1, decode_kind)
  use message_id <- decode.element(2, decode.text)
  use topic_hash <- decode.element(3, decode.text)
  use state <- decode.element(4, decode_state)
  use attempts <- decode.element(5, decode.int)
  use available_at <- decode.element(6, decode.int)
  use lease_owner <- decode.element(7, decode.optional(decode.text))
  use lease_until <- decode.element(8, decode.optional(decode.int))
  use last_error <- decode.element(9, decode.optional(decode.text))
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
}

fn job_decoder() -> decode.RowDecoder(Job) {
  use id <- decode.element(0, decode.text)
  use kind <- decode.element(1, decode_kind)
  use endpoint <- decode.element(2, decode.text)
  use payload <- decode.element(3, decode.bytea)
  use message_id <- decode.element(4, decode.text)
  use topic_hash <- decode.element(5, decode.text)
  use state <- decode.element(6, decode_state)
  use attempts <- decode.element(7, decode.int)
  use available_at <- decode.element(8, decode.int)
  use lease_owner <- decode.element(9, decode.optional(decode.text))
  use lease_until <- decode.element(10, decode.optional(decode.int))
  use last_error <- decode.element(11, decode.optional(decode.text))
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
}

fn decode_kind(value) {
  use raw <- result.try(decode.text(value))
  parse_kind(raw)
  |> result.map_error(fn(_) { pg_error.DecodeError("invalid delivery kind") })
}

fn decode_state(value) {
  use raw <- result.try(decode.text(value))
  parse_state(raw)
  |> result.map_error(fn(_) { pg_error.DecodeError("invalid delivery state") })
}

fn health(connection: postgleam.Connection) -> Result(Nil, delivery.Error) {
  postgleam.query(connection, "SELECT 1", [])
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
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

fn min(first: Int, second: Int) -> Int {
  case first < second {
    True -> first
    False -> second
  }
}

fn to_pg_error(error: delivery.Error) -> pg_error.Error {
  case error {
    delivery.NotFound -> postgleam.query_error("delivery not found")
    delivery.LeaseLost -> postgleam.query_error("delivery lease lost")
    delivery.Conflict -> postgleam.query_error("delivery conflict")
    delivery.InvalidPage -> postgleam.query_error("delivery page invalid")
    delivery.Unavailable(detail) -> postgleam.query_error(detail)
  }
}

fn map_transaction_error(error: pg_error.Error) -> delivery.Error {
  case error {
    pg_error.ConnectionError("delivery not found") -> delivery.NotFound
    pg_error.ConnectionError("delivery conflict") -> delivery.Conflict
    other -> map_error(other)
  }
}

fn map_error(error: pg_error.Error) -> delivery.Error {
  case error {
    pg_error.PgError(fields, _, _) ->
      case fields.code {
        "23505" -> delivery.Conflict
        _ ->
          delivery.Unavailable(
            "PostgreSQL " <> fields.code <> ": " <> fields.message,
          )
      }
    pg_error.ConnectionError(detail)
    | pg_error.AuthenticationError(detail)
    | pg_error.EncodeError(detail)
    | pg_error.DecodeError(detail)
    | pg_error.ProtocolError(detail)
    | pg_error.SocketError(detail) -> delivery.Unavailable(detail)
    pg_error.TimeoutError ->
      delivery.Unavailable("PostgreSQL request timed out")
  }
}
