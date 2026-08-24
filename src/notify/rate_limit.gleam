import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/result
import postgleam
import postgleam/config.{type Config}
import postgleam/decode
import postgleam/error as pg_error

pub type Decision {
  Allowed(remaining: Int, reset_at: Int)
  Limited(retry_after: Int, reset_at: Int)
}

/// Independent resource dimensions. A subject exhausting one bucket does not
/// consume credit from another bucket.
pub type Bucket {
  Request
  Subscription
  TopicCreation
  AuthFailure
  AttachmentBandwidth
  AttachmentQuota
}

pub type Policies {
  Policies(
    requests: Int,
    subscriptions: Int,
    topic_creations: Int,
    auth_failures: Int,
    attachment_mebibytes: Int,
    attachment_uploads: Int,
  )
}

pub type Error {
  Unavailable(String)
}

pub type Limiter {
  Limiter(
    limit: fn(Bucket) -> Int,
    window_seconds: Int,
    check: fn(Bucket, String, Int, Int) -> Result(Decision, Error),
  )
}

type TokenState {
  TokenState(tokens_scaled: Int, updated_at: Int)
}

type MemoryState {
  MemoryState(
    policies: Policies,
    window_seconds: Int,
    buckets: Dict(String, TokenState),
    last_cleanup_at: Int,
  )
}

type MemoryCommand {
  MemoryCheck(Bucket, String, Int, Int, Subject(Result(Decision, Error)))
}

type PostgresState {
  PostgresState(
    connection: postgleam.Connection,
    policies: Policies,
    window_seconds: Int,
    last_cleanup_at: Int,
  )
}

type PostgresCommand {
  PostgresCheck(Bucket, String, Int, Int, Subject(Result(Decision, Error)))
}

const postgres_migration = "
CREATE TABLE IF NOT EXISTS notify_token_buckets (
  bucket_key TEXT NOT NULL,
  client_key TEXT NOT NULL,
  tokens_scaled BIGINT NOT NULL,
  updated_at BIGINT NOT NULL,
  PRIMARY KEY (bucket_key, client_key)
);
CREATE INDEX IF NOT EXISTS notify_token_buckets_updated
  ON notify_token_buckets(updated_at);
"

pub fn memory(
  requests requests: Int,
  window_seconds window_seconds: Int,
) -> Result(Limiter, Error) {
  memory_with_policies(uniform_policies(requests), window_seconds:)
}

pub fn memory_with_policies(
  policies: Policies,
  window_seconds window_seconds: Int,
) -> Result(Limiter, Error) {
  use _ <- result.try(validate_policies(policies, window_seconds))
  use started <- result.try(
    actor.new(MemoryState(
      policies:,
      window_seconds:,
      buckets: dict.new(),
      last_cleanup_at: 0,
    ))
    |> actor.on_message(handle_memory)
    |> actor.start
    |> result.map_error(fn(_) {
      Unavailable("in-memory rate limiter failed to start")
    }),
  )
  let subject = started.data
  Ok(
    Limiter(
      limit: fn(bucket) { policy_limit(policies, bucket) },
      window_seconds:,
      check: fn(bucket, client_key, now, cost) {
        process.call(subject, 5000, fn(reply) {
          MemoryCheck(bucket, client_key, now, cost, reply)
        })
      },
    ),
  )
}

pub fn postgres(
  config: Config,
  requests requests: Int,
  window_seconds window_seconds: Int,
) -> Result(Limiter, Error) {
  postgres_with_policies(config, uniform_policies(requests), window_seconds:)
}

pub fn postgres_with_policies(
  config: Config,
  policies: Policies,
  window_seconds window_seconds: Int,
) -> Result(Limiter, Error) {
  use _ <- result.try(validate_policies(policies, window_seconds))
  use connection <- result.try(
    postgleam.connect(config) |> result.map_error(map_postgres_error),
  )
  case migrate_postgres(connection) {
    Error(error) -> {
      postgleam.disconnect(connection)
      Error(error)
    }
    Ok(_) -> start_postgres_actor(connection, policies, window_seconds)
  }
}

fn validate_policies(
  policies: Policies,
  window_seconds: Int,
) -> Result(Nil, Error) {
  let capacities = [
    policies.requests,
    policies.subscriptions,
    policies.topic_creations,
    policies.auth_failures,
    policies.attachment_mebibytes,
    policies.attachment_uploads,
  ]
  let valid = case window_seconds > 0 {
    False -> False
    True -> {
      let largest_safe_capacity = 9_223_372_036_854_775_807 / window_seconds
      capacities
      |> list.all(fn(capacity) {
        capacity > 0 && capacity <= largest_safe_capacity
      })
    }
  }
  case valid {
    True -> Ok(Nil)
    False ->
      Error(Unavailable(
        "rate limits and window must be positive and fit PostgreSQL BIGINT",
      ))
  }
}

fn handle_memory(
  state: MemoryState,
  command: MemoryCommand,
) -> actor.Next(MemoryState, MemoryCommand) {
  let MemoryCheck(bucket, client_key, now, cost, reply) = command
  case validate_cost(cost) {
    Error(error) -> {
      process.send(reply, Error(error))
      actor.continue(state)
    }
    Ok(_) -> {
      let state = cleanup_memory(state, now)
      let key = scoped_key(bucket, client_key)
      let capacity = policy_limit(state.policies, bucket)
      let initial = TokenState(capacity * state.window_seconds, now)
      let current = dict.get(state.buckets, key) |> result.unwrap(initial)
      let #(updated, decision) =
        evaluate(current, capacity, state.window_seconds, now, cost)
      process.send(reply, Ok(decision))
      actor.continue(
        MemoryState(..state, buckets: dict.insert(state.buckets, key, updated)),
      )
    }
  }
}

fn start_postgres_actor(
  connection: postgleam.Connection,
  policies: Policies,
  window_seconds: Int,
) -> Result(Limiter, Error) {
  use started <- result.try(
    actor.new(PostgresState(
      connection:,
      policies:,
      window_seconds:,
      last_cleanup_at: 0,
    ))
    |> actor.on_message(handle_postgres)
    |> actor.start
    |> result.map_error(fn(_) {
      Unavailable("PostgreSQL rate limiter failed to start")
    }),
  )
  let subject = started.data
  Ok(
    Limiter(
      limit: fn(bucket) { policy_limit(policies, bucket) },
      window_seconds:,
      check: fn(bucket, client_key, now, cost) {
        process.call(subject, 30_000, fn(reply) {
          PostgresCheck(bucket, client_key, now, cost, reply)
        })
      },
    ),
  )
}

fn handle_postgres(
  state: PostgresState,
  command: PostgresCommand,
) -> actor.Next(PostgresState, PostgresCommand) {
  let PostgresCheck(bucket, client_key, now, cost, reply) = command
  let cleanup = cleanup_due(state.last_cleanup_at, now, state.window_seconds)
  let outcome = case validate_cost(cost) {
    Error(error) -> Error(error)
    Ok(_) -> check_postgres(state, bucket, client_key, now, cost, cleanup)
  }
  process.send(reply, outcome)
  actor.continue(case cleanup {
    True -> PostgresState(..state, last_cleanup_at: int.max(now, 0))
    False -> state
  })
}

fn migrate_postgres(connection: postgleam.Connection) -> Result(Nil, Error) {
  postgleam.transaction(connection, fn(tx) {
    use _ <- result.try(
      postgleam.query(tx, "SELECT pg_advisory_xact_lock($1::bigint)", [
        postgleam.int(7_413_706_846),
      ]),
    )
    use _ <- result.try(postgleam.simple_query(tx, postgres_migration))
    Ok(Nil)
  })
  |> result.map_error(map_postgres_error)
}

fn check_postgres(
  state: PostgresState,
  bucket: Bucket,
  client_key: String,
  now: Int,
  cost: Int,
  cleanup: Bool,
) -> Result(Decision, Error) {
  postgleam.transaction(state.connection, fn(tx) {
    use _ <- result.try(case cleanup {
      False -> Ok(Nil)
      True ->
        postgleam.query(
          tx,
          "DELETE FROM notify_token_buckets WHERE updated_at < $1",
          [postgleam.int(now - state.window_seconds)],
        )
        |> result.map(fn(_) { Nil })
    })
    let scope = bucket_name(bucket)
    let capacity = policy_limit(state.policies, bucket)
    use _ <- result.try(
      postgleam.query(
        tx,
        "INSERT INTO notify_token_buckets(bucket_key, client_key, tokens_scaled, updated_at) VALUES ($1, $2, $3, $4) ON CONFLICT(bucket_key, client_key) DO NOTHING",
        [
          postgleam.text(scope),
          postgleam.text(client_key),
          postgleam.int(capacity * state.window_seconds),
          postgleam.int(now),
        ],
      ),
    )
    use current <- result.try(
      postgleam.query_one(
        tx,
        "SELECT tokens_scaled, updated_at FROM notify_token_buckets WHERE bucket_key = $1 AND client_key = $2 FOR UPDATE",
        [postgleam.text(scope), postgleam.text(client_key)],
        {
          use tokens_scaled <- decode.element(0, decode.int)
          use updated_at <- decode.element(1, decode.int)
          decode.success(TokenState(tokens_scaled:, updated_at:))
        },
      ),
    )
    let #(updated, decision) =
      evaluate(current, capacity, state.window_seconds, now, cost)
    let TokenState(tokens_scaled, updated_at) = updated
    use _ <- result.try(
      postgleam.query(
        tx,
        "UPDATE notify_token_buckets SET tokens_scaled = $1, updated_at = $2 WHERE bucket_key = $3 AND client_key = $4",
        [
          postgleam.int(tokens_scaled),
          postgleam.int(updated_at),
          postgleam.text(scope),
          postgleam.text(client_key),
        ],
      ),
    )
    Ok(decision)
  })
  |> result.map_error(map_postgres_error)
}

fn evaluate(
  state: TokenState,
  capacity: Int,
  window_seconds: Int,
  now: Int,
  cost: Int,
) -> #(TokenState, Decision) {
  let effective_now = int.max(now, state.updated_at)
  let maximum = capacity * window_seconds
  let available =
    int.min(
      maximum,
      state.tokens_scaled + { effective_now - state.updated_at } * capacity,
    )
  let required = cost * window_seconds
  case required <= maximum && available >= required {
    True -> {
      let remaining_scaled = available - required
      let reset_at =
        effective_now + ceiling_div(maximum - remaining_scaled, capacity)
      #(
        TokenState(tokens_scaled: remaining_scaled, updated_at: effective_now),
        Allowed(remaining: remaining_scaled / window_seconds, reset_at:),
      )
    }
    False -> {
      let retry_after = case required > maximum {
        True -> window_seconds
        False -> ceiling_div(required - available, capacity)
      }
      let reset_at = case required > maximum {
        True -> effective_now + window_seconds
        False -> effective_now + ceiling_div(maximum - available, capacity)
      }
      #(
        TokenState(tokens_scaled: available, updated_at: effective_now),
        Limited(retry_after: int.max(1, retry_after), reset_at:),
      )
    }
  }
}

fn validate_cost(cost: Int) -> Result(Nil, Error) {
  case cost > 0 {
    True -> Ok(Nil)
    False -> Error(Unavailable("rate-limit cost must be positive"))
  }
}

fn cleanup_memory(state: MemoryState, now: Int) -> MemoryState {
  case cleanup_due(state.last_cleanup_at, now, state.window_seconds) {
    False -> state
    True ->
      MemoryState(
        ..state,
        buckets: dict.filter(state.buckets, fn(_, bucket) {
          bucket.updated_at + state.window_seconds > now
        }),
        last_cleanup_at: int.max(now, 0),
      )
  }
}

fn cleanup_due(last_cleanup_at: Int, now: Int, window_seconds: Int) -> Bool {
  now >= last_cleanup_at + window_seconds
}

fn scoped_key(bucket: Bucket, client_key: String) -> String {
  bucket_name(bucket) <> "\u{0}" <> client_key
}

pub fn bucket_name(bucket: Bucket) -> String {
  case bucket {
    Request -> "request"
    Subscription -> "subscription"
    TopicCreation -> "topic_creation"
    AuthFailure -> "auth_failure"
    AttachmentBandwidth -> "attachment_bandwidth"
    AttachmentQuota -> "attachment_quota"
  }
}

fn uniform_policies(capacity: Int) -> Policies {
  Policies(
    requests: capacity,
    subscriptions: capacity,
    topic_creations: capacity,
    auth_failures: capacity,
    attachment_mebibytes: capacity,
    attachment_uploads: capacity,
  )
}

fn policy_limit(policies: Policies, bucket: Bucket) -> Int {
  case bucket {
    Request -> policies.requests
    Subscription -> policies.subscriptions
    TopicCreation -> policies.topic_creations
    AuthFailure -> policies.auth_failures
    AttachmentBandwidth -> policies.attachment_mebibytes
    AttachmentQuota -> policies.attachment_uploads
  }
}

fn ceiling_div(numerator: Int, denominator: Int) -> Int {
  { numerator + denominator - 1 } / denominator
}

fn map_postgres_error(error: pg_error.Error) -> Error {
  case error {
    pg_error.PgError(fields, _, _) ->
      Unavailable("PostgreSQL " <> fields.code <> ": " <> fields.message)
    pg_error.ConnectionError(detail)
    | pg_error.AuthenticationError(detail)
    | pg_error.EncodeError(detail)
    | pg_error.ProtocolError(detail)
    | pg_error.SocketError(detail)
    | pg_error.DecodeError(detail) -> Unavailable(detail)
    pg_error.TimeoutError -> Unavailable("PostgreSQL request timed out")
  }
}
