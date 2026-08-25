import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
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
    check_many: fn(List(#(Bucket, Int)), String, Int) ->
      Result(List(#(Bucket, Decision)), Error),
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

type PostgresCommand {
  PostgresCheckMany(
    List(#(Bucket, Int)),
    String,
    Int,
    Subject(Result(List(#(Bucket, Decision)), Error)),
  )
}

type PostgresState {
  PostgresState(
    subject: Subject(PostgresCommand),
    connection: postgleam.Connection,
    policies: Policies,
    window_seconds: Int,
    last_cleanup_at: Int,
  )
}

type PendingPostgresCheck {
  PendingPostgresCheck(
    charges: List(#(Bucket, Int)),
    client_key: String,
    now: Int,
    reply: Subject(Result(List(#(Bucket, Decision)), Error)),
  )
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

CREATE OR REPLACE FUNCTION notify_charge_token_bucket(
  requested_bucket_key TEXT,
  requested_client_key TEXT,
  maximum_tokens BIGINT,
  token_capacity BIGINT,
  token_window BIGINT,
  checked_at BIGINT,
  requested_cost BIGINT
)
RETURNS TABLE(
  remaining_tokens_scaled BIGINT,
  effective_checked_at BIGINT,
  charge_allowed BOOLEAN
)
LANGUAGE plpgsql
AS $notify_rate_limit$
DECLARE
  current_tokens BIGINT;
  current_updated_at BIGINT;
  effective_now BIGINT;
  available_tokens BIGINT;
  allowed BOOLEAN;
BEGIN
  INSERT INTO notify_token_buckets(
    bucket_key, client_key, tokens_scaled, updated_at
  )
  VALUES (
    requested_bucket_key, requested_client_key, maximum_tokens, checked_at
  )
  ON CONFLICT(bucket_key, client_key) DO NOTHING;

  SELECT bucket.tokens_scaled, bucket.updated_at
  INTO STRICT current_tokens, current_updated_at
  FROM notify_token_buckets AS bucket
  WHERE bucket.bucket_key = requested_bucket_key
    AND bucket.client_key = requested_client_key
  FOR UPDATE;

  effective_now := GREATEST(checked_at, current_updated_at);
  IF effective_now - current_updated_at >= token_window THEN
    available_tokens := maximum_tokens;
  ELSE
    available_tokens := LEAST(
      maximum_tokens,
      current_tokens + LEAST(
        maximum_tokens - current_tokens,
        (effective_now - current_updated_at) * token_capacity
      )
    );
  END IF;
  allowed := requested_cost <= token_capacity
    AND available_tokens >= requested_cost * token_window;
  IF allowed THEN
    available_tokens := available_tokens - requested_cost * token_window;
  END IF;

  UPDATE notify_token_buckets AS bucket
  SET tokens_scaled = available_tokens, updated_at = effective_now
  WHERE bucket.bucket_key = requested_bucket_key
    AND bucket.client_key = requested_client_key;

  RETURN QUERY SELECT available_tokens, effective_now, allowed;
END;
$notify_rate_limit$;

CREATE OR REPLACE FUNCTION notify_charge_token_buckets(
  requested_charges JSONB,
  requested_client_key TEXT,
  checked_at BIGINT,
  token_window BIGINT
)
RETURNS TABLE(
  charged_bucket_key TEXT,
  remaining_tokens_scaled BIGINT,
  effective_checked_at BIGINT,
  charge_allowed BOOLEAN
)
LANGUAGE plpgsql
AS $notify_rate_limit_batch$
DECLARE
  charge JSONB;
  requested_bucket_key TEXT;
  token_capacity BIGINT;
  requested_cost BIGINT;
  charged_tokens BIGINT;
  charged_at BIGINT;
  allowed BOOLEAN;
BEGIN
  FOR charge IN SELECT value FROM jsonb_array_elements(requested_charges)
  LOOP
    requested_bucket_key := charge ->> 'bucket_key';
    token_capacity := (charge ->> 'capacity')::BIGINT;
    requested_cost := (charge ->> 'cost')::BIGINT;
    SELECT
      charged.remaining_tokens_scaled,
      charged.effective_checked_at,
      charged.charge_allowed
    INTO STRICT charged_tokens, charged_at, allowed
    FROM notify_charge_token_bucket(
      requested_bucket_key,
      requested_client_key,
      token_capacity * token_window,
      token_capacity,
      token_window,
      checked_at,
      requested_cost
    ) AS charged;
    RETURN QUERY SELECT
      requested_bucket_key, charged_tokens, charged_at, allowed;
    EXIT WHEN NOT allowed;
  END LOOP;
END;
$notify_rate_limit_batch$;

CREATE OR REPLACE FUNCTION notify_charge_token_bucket_requests(
  requested_batches JSONB,
  token_window BIGINT
)
RETURNS TABLE(
  batch_index BIGINT,
  charged_bucket_key TEXT,
  remaining_tokens_scaled BIGINT,
  effective_checked_at BIGINT,
  charge_allowed BOOLEAN
)
LANGUAGE plpgsql
AS $notify_rate_limit_requests$
DECLARE
  requested_batch JSONB;
  requested_index BIGINT;
  requested_client_key TEXT;
  requested_checked_at BIGINT;
BEGIN
  FOR requested_batch, requested_index IN
    SELECT value, ordinality::BIGINT
    FROM jsonb_array_elements(requested_batches) WITH ORDINALITY
  LOOP
    requested_client_key := requested_batch ->> 'client_key';
    requested_checked_at := (requested_batch ->> 'checked_at')::BIGINT;
    RETURN QUERY
    SELECT
      requested_index,
      charged.charged_bucket_key,
      charged.remaining_tokens_scaled,
      charged.effective_checked_at,
      charged.charge_allowed
    FROM notify_charge_token_buckets(
      requested_batch -> 'charges',
      requested_client_key,
      requested_checked_at,
      token_window
    ) AS charged;
  END LOOP;
END;
$notify_rate_limit_requests$;
"

const postgres_batch_size = 64

const postgres_batch_wait_milliseconds = 1

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
      check_many: fn(charges, client_key, now) {
        sequential_checks(charges, fn(bucket, cost) {
          process.call(subject, 5000, fn(reply) {
            MemoryCheck(bucket, client_key, now, cost, reply)
          })
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
    actor.new_with_initialiser(1000, fn(subject) {
      Ok(
        actor.initialised(PostgresState(
          subject:,
          connection:,
          policies:,
          window_seconds:,
          last_cleanup_at: 0,
        ))
        |> actor.returning(subject),
      )
    })
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
        use decisions <- result.try(postgres_check_many(
          subject,
          [#(bucket, cost)],
          client_key,
          now,
        ))
        case decisions {
          [#(_, decision)] -> Ok(decision)
          _ ->
            Error(Unavailable("PostgreSQL rate limiter returned no decision"))
        }
      },
      check_many: fn(charges, client_key, now) {
        postgres_check_many(subject, charges, client_key, now)
      },
    ),
  )
}

fn postgres_check_many(
  subject: Subject(PostgresCommand),
  charges: List(#(Bucket, Int)),
  client_key: String,
  now: Int,
) -> Result(List(#(Bucket, Decision)), Error) {
  case charges {
    [] -> Ok([])
    _ ->
      process.call(subject, 30_000, fn(reply) {
        PostgresCheckMany(charges, client_key, now, reply)
      })
  }
}

fn handle_postgres(
  state: PostgresState,
  command: PostgresCommand,
) -> actor.Next(PostgresState, PostgresCommand) {
  let commands =
    collect_postgres_commands(
      state.subject,
      postgres_batch_size - 1,
      postgres_batch_wait_milliseconds,
      [command],
    )
  let pending = prepare_postgres_checks(commands, [])
  let checked_at =
    pending
    |> list.fold(0, fn(latest, check) { int.max(latest, check.now) })
  let cleanup =
    cleanup_due(state.last_cleanup_at, checked_at, state.window_seconds)
  case pending {
    [] -> Nil
    _ -> {
      let outcome = check_postgres_batches(state, pending, cleanup)
      send_postgres_batch_results(
        pending,
        case outcome {
          Ok(rows) -> Ok(rows)
          Error(error) -> Error(error)
        },
        state.policies,
        state.window_seconds,
        1,
      )
    }
  }
  actor.continue(case cleanup {
    True -> PostgresState(..state, last_cleanup_at: int.max(checked_at, 0))
    False -> state
  })
}

fn collect_postgres_commands(
  subject: Subject(PostgresCommand),
  remaining: Int,
  wait_milliseconds: Int,
  accumulated: List(PostgresCommand),
) -> List(PostgresCommand) {
  case remaining > 0 {
    False -> list.reverse(accumulated)
    True ->
      case process.receive(subject, wait_milliseconds) {
        Ok(command) ->
          collect_postgres_commands(subject, remaining - 1, 0, [
            command,
            ..accumulated
          ])
        Error(_) -> list.reverse(accumulated)
      }
  }
}

fn prepare_postgres_checks(
  commands: List(PostgresCommand),
  accumulated: List(PendingPostgresCheck),
) -> List(PendingPostgresCheck) {
  case commands {
    [] -> list.reverse(accumulated)
    [PostgresCheckMany(charges, client_key, now, reply), ..remaining] ->
      case list.try_each(charges, fn(charge) { validate_cost(charge.1) }) {
        Error(error) -> {
          process.send(reply, Error(error))
          prepare_postgres_checks(remaining, accumulated)
        }
        Ok(_) ->
          prepare_postgres_checks(remaining, [
            PendingPostgresCheck(charges:, client_key:, now:, reply:),
            ..accumulated
          ])
      }
  }
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

type PostgresCharge {
  PostgresCharge(
    batch_index: Int,
    scope: String,
    state: TokenState,
    allowed: Bool,
  )
}

fn check_postgres_batches(
  state: PostgresState,
  pending: List(PendingPostgresCheck),
  cleanup: Bool,
) -> Result(List(PostgresCharge), Error) {
  use _ <- result.try(case cleanup {
    False -> Ok(Nil)
    True ->
      postgleam.query(
        state.connection,
        "DELETE FROM notify_token_buckets WHERE updated_at < $1",
        [
          postgleam.int(
            pending
            |> list.fold(0, fn(latest, check) { int.max(latest, check.now) })
            |> fn(now) { now - state.window_seconds },
          ),
        ],
      )
      |> result.map(fn(_) { Nil })
      |> result.map_error(map_postgres_error)
  })
  let encoded_batches =
    pending
    |> json.array(fn(check) {
      json.object([
        #("client_key", json.string(check.client_key)),
        #("checked_at", json.int(check.now)),
        #(
          "charges",
          check.charges
            |> json.array(fn(charge) {
              json.object([
                #("bucket_key", json.string(bucket_name(charge.0))),
                #("capacity", json.int(policy_limit(state.policies, charge.0))),
                #("cost", json.int(charge.1)),
              ])
            }),
        ),
      ])
    })
    |> json.to_string
  use response <- result.try(
    postgleam.query_with(
      state.connection,
      "SELECT batch_index, charged_bucket_key, remaining_tokens_scaled, effective_checked_at, charge_allowed FROM notify_charge_token_bucket_requests($1, $2) ORDER BY batch_index",
      [
        postgleam.jsonb(encoded_batches),
        postgleam.int(state.window_seconds),
      ],
      {
        use batch_index <- decode.element(0, decode.int)
        use scope <- decode.element(1, decode.text)
        use tokens_scaled <- decode.element(2, decode.int)
        use updated_at <- decode.element(3, decode.int)
        use allowed <- decode.element(4, decode.bool)
        decode.success(PostgresCharge(
          batch_index:,
          scope:,
          state: TokenState(tokens_scaled:, updated_at:),
          allowed:,
        ))
      },
    )
    |> result.map_error(map_postgres_error),
  )
  Ok(response.rows)
}

fn send_postgres_batch_results(
  pending: List(PendingPostgresCheck),
  outcome: Result(List(PostgresCharge), Error),
  policies: Policies,
  window_seconds: Int,
  batch_index: Int,
) -> Nil {
  case pending {
    [] -> Nil
    [check, ..remaining] -> {
      let result = case outcome {
        Error(error) -> Error(error)
        Ok(rows) ->
          postgres_decisions(
            check.charges,
            rows
              |> list.filter(fn(row) { row.batch_index == batch_index }),
            policies,
            window_seconds,
            [],
          )
      }
      process.send(check.reply, result)
      send_postgres_batch_results(
        remaining,
        outcome,
        policies,
        window_seconds,
        batch_index + 1,
      )
    }
  }
}

fn postgres_decisions(
  charges: List(#(Bucket, Int)),
  rows: List(PostgresCharge),
  policies: Policies,
  window_seconds: Int,
  accumulated: List(#(Bucket, Decision)),
) -> Result(List(#(Bucket, Decision)), Error) {
  case charges, rows {
    [], [] -> Ok(list.reverse(accumulated))
    [#(bucket, cost), ..remaining_charges], [row, ..remaining_rows] -> {
      case row.scope == bucket_name(bucket) {
        False ->
          Error(Unavailable("PostgreSQL rate limiter returned invalid batch"))
        True -> {
          let decision =
            postgres_decision(
              row.state,
              row.allowed,
              policy_limit(policies, bucket),
              window_seconds,
              cost,
            )
          case decision {
            Limited(..) if remaining_rows == [] ->
              Ok(list.reverse([#(bucket, decision), ..accumulated]))
            Allowed(..) ->
              postgres_decisions(
                remaining_charges,
                remaining_rows,
                policies,
                window_seconds,
                [#(bucket, decision), ..accumulated],
              )
            _ ->
              Error(Unavailable(
                "PostgreSQL rate limiter returned invalid batch",
              ))
          }
        }
      }
    }
    _, _ -> Error(Unavailable("PostgreSQL rate limiter returned invalid batch"))
  }
}

fn sequential_checks(
  charges: List(#(Bucket, Int)),
  check: fn(Bucket, Int) -> Result(Decision, Error),
) -> Result(List(#(Bucket, Decision)), Error) {
  sequential_checks_loop(charges, check, [])
}

fn sequential_checks_loop(
  charges: List(#(Bucket, Int)),
  check: fn(Bucket, Int) -> Result(Decision, Error),
  accumulated: List(#(Bucket, Decision)),
) -> Result(List(#(Bucket, Decision)), Error) {
  case charges {
    [] -> Ok(list.reverse(accumulated))
    [#(bucket, cost), ..remaining] -> {
      use decision <- result.try(check(bucket, cost))
      let accumulated = [#(bucket, decision), ..accumulated]
      case decision {
        Limited(..) -> Ok(list.reverse(accumulated))
        Allowed(..) -> sequential_checks_loop(remaining, check, accumulated)
      }
    }
  }
}

fn postgres_decision(
  state: TokenState,
  allowed: Bool,
  capacity: Int,
  window_seconds: Int,
  cost: Int,
) -> Decision {
  let TokenState(tokens_scaled, updated_at) = state
  case allowed {
    True ->
      Allowed(
        remaining: tokens_scaled / window_seconds,
        reset_at: updated_at
          + ceiling_div(capacity * window_seconds - tokens_scaled, capacity),
      )
    False -> {
      let retry_after = case cost > capacity {
        True -> window_seconds
        False -> ceiling_div(cost * window_seconds - tokens_scaled, capacity)
      }
      let reset_at = case cost > capacity {
        True -> updated_at + window_seconds
        False ->
          updated_at
          + ceiling_div(capacity * window_seconds - tokens_scaled, capacity)
      }
      Limited(retry_after: int.max(1, retry_after), reset_at:)
    }
  }
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
