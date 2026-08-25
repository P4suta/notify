import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import notify/cluster/health as cluster_health
import notify/core/message.{type Message}
import notify/core/message_json
import notify/core/topic
import notify/delivery
import notify/storage.{type Query, type Storage}
import postgleam
import postgleam/config.{type Config}
import postgleam/decode
import postgleam/error as pg_error

pub type ClusterEvent {
  ClusterEvent(sequence: Int, origin_node: String, message: Message)
}

pub type Adapter {
  Adapter(
    storage: Storage,
    commit: storage.AtomicCommit,
    fetch_events: fn(String, Int) -> Result(List(ClusterEvent), storage.Error),
    ack_events: fn(String, Int) -> Result(Nil, storage.Error),
    cluster_health: cluster_health.Store,
    pool_size: Int,
  )
}

type State {
  State(config: Config, connection: postgleam.Connection, node_id: String)
}

type Worker {
  Worker(subject: Subject(Command))
}

type CommitCommand {
  CommitMessage(
    Message,
    List(delivery.NewJob),
    Subject(Result(Message, storage.Error)),
  )
  CommitHealth(Subject(Result(Nil, storage.Error)))
  CommitShutdown(Subject(Nil))
}

type CommitState {
  CommitState(subject: Subject(CommitCommand), worker: State)
}

type CommitWorker {
  CommitWorker(subject: Subject(CommitCommand))
}

type CommitRun {
  ContinueCommit(CommitState)
  StopCommit
}

type BatchCommitResult {
  BatchCommitResult(index: Int, succeeded: Bool, sequence: Option(Int))
}

type PoolState {
  PoolState(workers: List(Worker), remaining: List(Worker))
}

type PoolCommand {
  Checkout(Subject(Worker))
}

type Command {
  RunQuery(Query, Subject(Result(List(Message), storage.Error)))
  HasAttachment(topic.Topic, String, Subject(Result(Bool, storage.Error)))
  ReleaseDue(Int, Int, Subject(Result(List(Message), storage.Error)))
  CleanupExpired(Int, Subject(Result(Int, storage.Error)))
  Stats(Subject(Result(storage.Stats, storage.Error)))
  Migrate(Subject(Result(Nil, storage.Error)))
  Health(Subject(Result(Nil, storage.Error)))
  FetchEvents(String, Int, Subject(Result(List(ClusterEvent), storage.Error)))
  AckEvents(String, Int, Subject(Result(Nil, storage.Error)))
  InspectCluster(
    Option(String),
    Int,
    Subject(Result(cluster_health.Snapshot, storage.Error)),
  )
  Shutdown(Subject(Nil))
}

const default_pool_size = 4

const event_commit_lock_key = 7_413_706_844

pub fn event_commit_lock() -> Int {
  event_commit_lock_key
}

const migration = "
CREATE TABLE IF NOT EXISTS notify_schema_migrations (
  version BIGINT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS notify_messages (
  position BIGSERIAL PRIMARY KEY,
  id TEXT NOT NULL UNIQUE,
  topic TEXT NOT NULL,
  time BIGINT NOT NULL,
  expires BIGINT,
  scheduled BOOLEAN NOT NULL DEFAULT FALSE,
  sequence_id TEXT,
  payload JSONB NOT NULL
);
CREATE INDEX IF NOT EXISTS notify_messages_topic_position
  ON notify_messages(topic, position);
CREATE INDEX IF NOT EXISTS notify_messages_due
  ON notify_messages(time, position) WHERE scheduled = TRUE;
CREATE INDEX IF NOT EXISTS notify_messages_expires
  ON notify_messages(expires) WHERE expires IS NOT NULL;

CREATE TABLE IF NOT EXISTS notify_event_log (
  sequence BIGSERIAL PRIMARY KEY,
  message_id TEXT NOT NULL,
  event TEXT NOT NULL,
  topic TEXT NOT NULL,
  time BIGINT NOT NULL,
  origin_node TEXT NOT NULL,
  payload JSONB NOT NULL
);
CREATE INDEX IF NOT EXISTS notify_event_log_topic_sequence
  ON notify_event_log(topic, sequence);
CREATE INDEX IF NOT EXISTS notify_event_log_message_sequence
  ON notify_event_log(message_id, sequence);

CREATE TABLE IF NOT EXISTS notify_node_cursors (
  node_id TEXT PRIMARY KEY,
  sequence BIGINT NOT NULL DEFAULT 0,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS notify_node_cursors_updated_at
  ON notify_node_cursors(updated_at);

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

CREATE OR REPLACE FUNCTION notify_commit_message_batch(
  requested_messages JSONB,
  requested_origin_node TEXT,
  requested_lock_key BIGINT
)
RETURNS TABLE(
  batch_index BIGINT,
  commit_succeeded BOOLEAN,
  event_sequence BIGINT
)
LANGUAGE plpgsql
AS $notify_commit_batch$
DECLARE
  requested_message JSONB;
  requested_index BIGINT;
  inserted_id TEXT;
  committed_sequence BIGINT;
  last_message_id TEXT := NULL;
BEGIN
  PERFORM pg_advisory_xact_lock(requested_lock_key);
  FOR requested_message, requested_index IN
    SELECT value, ordinality::BIGINT
    FROM jsonb_array_elements(requested_messages) WITH ORDINALITY
    ORDER BY ordinality
  LOOP
    inserted_id := NULL;
    INSERT INTO notify_messages(
      id, topic, time, expires, scheduled, sequence_id, payload
    )
    VALUES (
      requested_message ->> 'id',
      requested_message ->> 'topic',
      (requested_message ->> 'time')::BIGINT,
      (requested_message ->> 'expires')::BIGINT,
      (requested_message ->> 'scheduled')::BOOLEAN,
      requested_message ->> 'sequence_id',
      requested_message -> 'payload'
    )
    ON CONFLICT(id) DO NOTHING
    RETURNING id INTO inserted_id;

    IF inserted_id IS NULL THEN
      RETURN QUERY SELECT requested_index, FALSE, NULL::BIGINT;
    ELSE
      INSERT INTO notify_event_log(
        message_id, event, topic, time, origin_node, payload
      )
      VALUES (
        inserted_id,
        requested_message ->> 'event',
        requested_message ->> 'topic',
        (requested_message ->> 'time')::BIGINT,
        requested_origin_node,
        requested_message -> 'payload'
      )
      RETURNING sequence INTO committed_sequence;
      last_message_id := inserted_id;
      RETURN QUERY SELECT requested_index, TRUE, committed_sequence;
    END IF;
  END LOOP;

  IF last_message_id IS NOT NULL THEN
    PERFORM pg_notify('notify_events', last_message_id);
  END IF;
END;
$notify_commit_batch$;

INSERT INTO notify_schema_migrations(version) VALUES (1)
ON CONFLICT(version) DO NOTHING;
"

const query_page_size = 256

const commit_batch_size = 64

const commit_batch_wait_milliseconds = 1

const page_query = "
SELECT m.position, m.payload, m.scheduled
FROM notify_messages AS m
WHERE m.position > $1
  AND m.topic IN (SELECT jsonb_array_elements_text($2::jsonb))
  AND COALESCE((m.payload->>'_notify_cached')::boolean, TRUE) = TRUE
  AND ($3::boolean = TRUE OR m.scheduled = FALSE)
  AND ($4::boolean = FALSE OR m.time >= $5)
  AND ($6::boolean = FALSE OR m.id = $7)
  AND ($8::boolean = FALSE OR m.payload->>'message' = $9)
  AND ($10::boolean = FALSE OR m.payload->>'title' = $11)
  AND (
    $12::boolean = FALSE
    OR COALESCE((m.payload->>'priority')::bigint, 3) IN (
      SELECT value::bigint
      FROM jsonb_array_elements_text($13::jsonb) AS priority(value)
    )
  )
  AND NOT EXISTS (
    SELECT 1
    FROM jsonb_array_elements_text($14::jsonb) AS required_tag(value)
    WHERE NOT (COALESCE(m.payload->'tags', '[]'::jsonb) ? required_tag.value)
  )
  AND (
    $15::boolean = FALSE
    OR m.position = (
      SELECT MAX(latest.position)
      FROM notify_messages AS latest
      WHERE latest.topic = m.topic
        AND latest.scheduled = FALSE
        AND COALESCE((latest.payload->>'_notify_cached')::boolean, TRUE) = TRUE
    )
  )
ORDER BY m.position ASC
LIMIT $16
"

const after_id_cursor_query = "
SELECT position
FROM notify_messages
WHERE id = $1
  AND topic IN (SELECT jsonb_array_elements_text($2::jsonb))
  AND COALESCE((payload->>'_notify_cached')::boolean, TRUE) = TRUE
  AND ($3::boolean = TRUE OR scheduled = FALSE)
LIMIT 1
"

pub fn start(
  config: Config,
  node_id: String,
) -> Result(Adapter, storage.Error) {
  start_with_pool_size(config, node_id, default_pool_size)
}

pub fn start_with_pool_size(
  config: Config,
  node_id: String,
  size: Int,
) -> Result(Adapter, storage.Error) {
  let requested_pool_size = max(1, size)
  use connections <- result.try(
    connect_many(config, requested_pool_size + 2, []),
  )
  let assert [commit_connection, event_connection, ..pool_connections] =
    connections
  case migrate(commit_connection) {
    Error(error) -> {
      disconnect_all(connections)
      Error(error)
    }
    Ok(_) ->
      case start_workers(config, node_id, pool_connections, []) {
        Error(error) -> {
          postgleam.disconnect(commit_connection)
          postgleam.disconnect(event_connection)
          Error(error)
        }
        Ok(workers) ->
          case
            start_worker(State(config:, connection: event_connection, node_id:))
          {
            Error(error) -> {
              shutdown_workers(workers)
              postgleam.disconnect(commit_connection)
              postgleam.disconnect(event_connection)
              Error(error)
            }
            Ok(event_worker) ->
              case
                start_commit_worker(State(
                  config:,
                  connection: commit_connection,
                  node_id:,
                ))
              {
                Error(error) -> {
                  shutdown_workers([event_worker, ..workers])
                  postgleam.disconnect(commit_connection)
                  Error(error)
                }
                Ok(commit_worker) ->
                  case start_pool(workers) {
                    Error(error) -> {
                      shutdown_workers([event_worker, ..workers])
                      shutdown_commit_worker(commit_worker)
                      Error(error)
                    }
                    Ok(pool) ->
                      Ok(adapter(pool, workers, event_worker, commit_worker))
                  }
              }
          }
      }
  }
}

fn connect_many(
  config: Config,
  remaining: Int,
  connected: List(postgleam.Connection),
) -> Result(List(postgleam.Connection), storage.Error) {
  case remaining {
    0 -> Ok(list.reverse(connected))
    _ ->
      case postgleam.connect(config) {
        Ok(connection) ->
          connect_many(config, remaining - 1, [connection, ..connected])
        Error(error) -> {
          disconnect_all(connected)
          Error(map_error(error))
        }
      }
  }
}

fn disconnect_all(connections: List(postgleam.Connection)) -> Nil {
  list.each(connections, postgleam.disconnect)
}

fn start_workers(
  config: Config,
  node_id: String,
  connections: List(postgleam.Connection),
  started: List(Worker),
) -> Result(List(Worker), storage.Error) {
  case connections {
    [] -> Ok(list.reverse(started))
    [connection, ..rest] ->
      case start_worker(State(config:, connection:, node_id:)) {
        Ok(worker) -> start_workers(config, node_id, rest, [worker, ..started])
        Error(error) -> {
          shutdown_workers(started)
          disconnect_all([connection, ..rest])
          Error(error)
        }
      }
  }
}

fn start_worker(state: State) -> Result(Worker, storage.Error) {
  use started <- result.try(
    actor.new(state)
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(fn(_) {
      storage.Unavailable("PostgreSQL storage actor failed to start")
    }),
  )
  Ok(Worker(started.data))
}

fn start_commit_worker(state: State) -> Result(CommitWorker, storage.Error) {
  use started <- result.try(
    actor.new_with_initialiser(1000, fn(subject) {
      Ok(
        actor.initialised(CommitState(subject:, worker: state))
        |> actor.returning(subject),
      )
    })
    |> actor.on_message(handle_commit)
    |> actor.start
    |> result.map_error(fn(_) {
      storage.Unavailable("PostgreSQL commit actor failed to start")
    }),
  )
  Ok(CommitWorker(started.data))
}

fn start_pool(
  workers: List(Worker),
) -> Result(Subject(PoolCommand), storage.Error) {
  actor.new(PoolState(workers:, remaining: workers))
  |> actor.on_message(handle_pool)
  |> actor.start
  |> result.map(fn(started) { started.data })
  |> result.map_error(fn(_) {
    storage.Unavailable("PostgreSQL storage pool failed to start")
  })
}

fn handle_pool(
  state: PoolState,
  command: PoolCommand,
) -> actor.Next(PoolState, PoolCommand) {
  let PoolState(workers:, remaining:) = state
  case command, remaining {
    Checkout(reply), [worker, ..rest] -> {
      process.send(reply, worker)
      actor.continue(
        PoolState(workers:, remaining: case rest {
          [] -> workers
          _ -> rest
        }),
      )
    }
    Checkout(_), [] -> actor.continue(PoolState(..state, remaining: workers))
  }
}

fn adapter(
  pool: Subject(PoolCommand),
  workers: List(Worker),
  event_worker: Worker,
  commit_worker: CommitWorker,
) -> Adapter {
  let persistent =
    storage.Storage(
      migrate: fn() { call(pool, Migrate) },
      save: fn(message) {
        call_commit_worker(commit_worker, fn(reply) {
          CommitMessage(message, [], reply)
        })
      },
      query: fn(query) { call(pool, fn(reply) { RunQuery(query, reply) }) },
      has_attachment: fn(topic, key) {
        call(pool, fn(reply) { HasAttachment(topic, key, reply) })
      },
      release_due: fn(now, limit) {
        call(pool, fn(reply) { ReleaseDue(now, limit, reply) })
      },
      cleanup_expired: fn(now) {
        call(pool, fn(reply) { CleanupExpired(now, reply) })
      },
      stats: fn() { call(pool, Stats) },
      health: fn() { health_all(workers, event_worker, commit_worker) },
    )
  Adapter(
    storage: persistent,
    commit: storage.AtomicCommit(fn(message, jobs) {
      call_commit_worker(commit_worker, fn(reply) {
        CommitMessage(message, jobs, reply)
      })
    }),
    fetch_events: fn(node_id, limit) {
      call_worker(event_worker, fn(reply) { FetchEvents(node_id, limit, reply) })
    },
    ack_events: fn(node_id, sequence) {
      call_worker(event_worker, fn(reply) {
        AckEvents(node_id, sequence, reply)
      })
    },
    cluster_health: cluster_health.Store(fn(after, limit) {
      case limit >= 1 && limit <= 100 {
        False -> Error(cluster_health.InvalidPage)
        True ->
          call(pool, fn(reply) { InspectCluster(after, limit, reply) })
          |> result.map_error(cluster_health_error)
      }
    }),
    pool_size: list.length(workers),
  )
}

fn call(
  pool: Subject(PoolCommand),
  command: fn(Subject(reply)) -> Command,
) -> reply {
  let worker = process.call(pool, 30_000, Checkout)
  call_worker(worker, command)
}

fn call_worker(
  worker: Worker,
  command: fn(Subject(reply)) -> Command,
) -> reply {
  let Worker(subject) = worker
  process.call(subject, 30_000, command)
}

fn call_commit_worker(
  worker: CommitWorker,
  command: fn(Subject(reply)) -> CommitCommand,
) -> reply {
  let CommitWorker(subject) = worker
  process.call(subject, 30_000, command)
}

fn health_all(
  workers: List(Worker),
  event_worker: Worker,
  commit_worker: CommitWorker,
) -> Result(Nil, storage.Error) {
  use _ <- result.try(
    list.try_each(workers, fn(worker) { call_worker(worker, Health) }),
  )
  use _ <- result.try(call_worker(event_worker, Health))
  call_commit_worker(commit_worker, CommitHealth)
}

fn shutdown_workers(workers: List(Worker)) -> Nil {
  list.each(workers, fn(worker) { call_worker(worker, Shutdown) })
}

fn shutdown_commit_worker(worker: CommitWorker) -> Nil {
  call_commit_worker(worker, CommitShutdown)
}

fn handle_commit(
  state: CommitState,
  command: CommitCommand,
) -> actor.Next(CommitState, CommitCommand) {
  let commands =
    collect_commit_commands(
      state.subject,
      commit_batch_size - 1,
      commit_batch_wait_milliseconds,
      [command],
    )
  case run_commit_commands(state, commands) {
    ContinueCommit(state) -> actor.continue(state)
    StopCommit -> actor.stop()
  }
}

fn collect_commit_commands(
  subject: Subject(CommitCommand),
  remaining: Int,
  wait_milliseconds: Int,
  accumulated: List(CommitCommand),
) -> List(CommitCommand) {
  case remaining > 0 {
    False -> list.reverse(accumulated)
    True ->
      case process.receive(subject, wait_milliseconds) {
        Ok(command) ->
          collect_commit_commands(subject, remaining - 1, 0, [
            command,
            ..accumulated
          ])
        Error(_) -> list.reverse(accumulated)
      }
  }
}

fn run_commit_commands(
  state: CommitState,
  commands: List(CommitCommand),
) -> CommitRun {
  case commands {
    [] -> ContinueCommit(state)
    [CommitMessage(_, [], _), ..] -> {
      let #(batch, remaining) = take_fast_commit_prefix(commands, [])
      let outcome = fast_commit_batch(state.worker, batch)
      send_fast_commit_results(batch, outcome)
      run_commit_commands(
        CommitState(..state, worker: recover_connection(state.worker, outcome)),
        remaining,
      )
    }
    [CommitMessage(message, jobs, reply), ..remaining] -> {
      let payload = message_json.encode_storage(message) |> json.to_string
      let outcome = transactional_commit(state.worker, message, payload, jobs)
      process.send(reply, outcome)
      run_commit_commands(
        CommitState(..state, worker: recover_connection(state.worker, outcome)),
        remaining,
      )
    }
    [CommitHealth(reply), ..remaining] -> {
      let outcome = health(state.worker.connection)
      process.send(reply, outcome)
      run_commit_commands(
        CommitState(..state, worker: recover_connection(state.worker, outcome)),
        remaining,
      )
    }
    [CommitShutdown(reply), ..] -> {
      postgleam.disconnect(state.worker.connection)
      process.send(reply, Nil)
      StopCommit
    }
  }
}

fn take_fast_commit_prefix(
  commands: List(CommitCommand),
  accumulated: List(CommitCommand),
) -> #(List(CommitCommand), List(CommitCommand)) {
  case commands {
    [CommitMessage(message, [], reply), ..remaining] ->
      take_fast_commit_prefix(remaining, [
        CommitMessage(message, [], reply),
        ..accumulated
      ])
    _ -> #(list.reverse(accumulated), commands)
  }
}

fn fast_commit_batch(
  state: State,
  commands: List(CommitCommand),
) -> Result(List(BatchCommitResult), storage.Error) {
  let encoded_messages =
    commands
    |> json.array(fn(command) {
      let assert CommitMessage(message, [], _) = command
      json.object([
        #("id", json.string(message.id)),
        #("topic", json.string(topic.to_string(message.topic))),
        #("time", json.int(message.time)),
        #("expires", json.nullable(message.expires, json.int)),
        #("scheduled", json.bool(message.scheduled)),
        #("sequence_id", json.nullable(message.sequence_id, json.string)),
        #("event", json.string(message.event |> message.event_to_string)),
        #("payload", message_json.encode_storage(message)),
      ])
    })
    |> json.to_string
  postgleam.query_with(
    state.connection,
    "SELECT batch_index, commit_succeeded, event_sequence FROM notify_commit_message_batch($1, $2, $3) ORDER BY batch_index",
    [
      postgleam.jsonb(encoded_messages),
      postgleam.text(state.node_id),
      postgleam.int(event_commit_lock_key),
    ],
    {
      use index <- decode.element(0, decode.int)
      use succeeded <- decode.element(1, decode.bool)
      use sequence <- decode.element(2, decode.optional(decode.int))
      decode.success(BatchCommitResult(index:, succeeded:, sequence:))
    },
  )
  |> result.map(fn(response) { response.rows })
  |> result.map_error(map_error)
}

fn send_fast_commit_results(
  commands: List(CommitCommand),
  outcome: Result(List(BatchCommitResult), storage.Error),
) -> Nil {
  case outcome {
    Error(error) ->
      list.each(commands, fn(command) {
        let assert CommitMessage(_, [], reply) = command
        process.send(reply, Error(error))
      })
    Ok(rows) ->
      case
        list.length(commands) == list.length(rows)
        && valid_batch_commit_rows(rows, 1, None)
      {
        False ->
          list.each(commands, fn(command) {
            let assert CommitMessage(_, [], reply) = command
            process.send(
              reply,
              Error(storage.Unavailable(
                "PostgreSQL commit actor returned an invalid batch",
              )),
            )
          })
        True -> send_fast_commit_rows(commands, rows)
      }
  }
}

fn valid_batch_commit_rows(
  rows: List(BatchCommitResult),
  expected_index: Int,
  previous_sequence: Option(Int),
) -> Bool {
  case rows {
    [] -> True
    [row, ..remaining] -> {
      let #(valid_sequence, next_sequence) = case
        row.succeeded,
        row.sequence,
        previous_sequence
      {
        True, Some(sequence), None -> #(sequence > 0, Some(sequence))
        True, Some(sequence), Some(previous) -> #(
          sequence > previous,
          Some(sequence),
        )
        False, None, _ -> #(True, previous_sequence)
        _, _, _ -> #(False, previous_sequence)
      }
      row.index == expected_index
      && valid_sequence
      && valid_batch_commit_rows(remaining, expected_index + 1, next_sequence)
    }
  }
}

fn send_fast_commit_rows(
  commands: List(CommitCommand),
  rows: List(BatchCommitResult),
) -> Nil {
  case commands, rows {
    [], [] -> Nil
    [CommitMessage(message, [], reply), ..remaining_commands],
      [row, ..remaining_rows]
    -> {
      process.send(reply, case row.succeeded {
        True -> Ok(message)
        False -> Error(storage.Conflict("duplicate message ID"))
      })
      send_fast_commit_rows(remaining_commands, remaining_rows)
    }
    _, _ -> Nil
  }
}

fn handle(state: State, command: Command) -> actor.Next(State, Command) {
  case command {
    RunQuery(query, reply) -> respond(state, reply, run_query(state, query))
    HasAttachment(topic, key, reply) ->
      respond(state, reply, has_attachment(state.connection, topic, key))
    ReleaseDue(now, limit, reply) ->
      respond(state, reply, release_due(state, now, limit))
    CleanupExpired(now, reply) ->
      respond(state, reply, cleanup_expired(state.connection, now))
    Stats(reply) -> respond(state, reply, stats(state.connection))
    Migrate(reply) -> respond(state, reply, migrate(state.connection))
    Health(reply) -> respond(state, reply, health(state.connection))
    FetchEvents(node_id, limit, reply) ->
      respond(state, reply, fetch_events(state.connection, node_id, limit))
    AckEvents(node_id, sequence, reply) ->
      respond(state, reply, ack_events(state.connection, node_id, sequence))
    InspectCluster(after, limit, reply) ->
      respond(
        state,
        reply,
        inspect_cluster(state.connection, state.node_id, after, limit),
      )
    Shutdown(reply) -> {
      postgleam.disconnect(state.connection)
      process.send(reply, Nil)
      actor.stop()
    }
  }
}

fn respond(
  state: State,
  reply: Subject(Result(a, storage.Error)),
  value: Result(a, storage.Error),
) -> actor.Next(State, Command) {
  process.send(reply, value)
  actor.continue(recover_connection(state, value))
}

fn recover_connection(state: State, value: Result(a, storage.Error)) -> State {
  case value {
    Error(storage.Unavailable(_)) ->
      case postgleam.connect(state.config) {
        Error(_) -> state
        Ok(connection) -> {
          postgleam.disconnect(state.connection)
          State(..state, connection: connection)
        }
      }
    _ -> state
  }
}

fn migrate(connection: postgleam.Connection) -> Result(Nil, storage.Error) {
  postgleam.transaction(connection, fn(tx) {
    use _ <- result.try(
      postgleam.query(tx, "SELECT pg_advisory_xact_lock($1::bigint)", [
        postgleam.int(7_413_706_843),
      ]),
    )
    use _ <- result.try(postgleam.simple_query(tx, migration))
    Ok(Nil)
  })
  |> result.map_error(map_error)
}

fn transactional_commit(
  state: State,
  message: Message,
  payload: String,
  jobs: List(delivery.NewJob),
) -> Result(Message, storage.Error) {
  postgleam.transaction(state.connection, fn(tx) {
    use _ <- result.try(lock_event_commit(tx))
    use _ <- result.try(
      postgleam.query(
        tx,
        "INSERT INTO notify_messages(id, topic, time, expires, scheduled, sequence_id, payload) VALUES ($1, $2, $3, $4, $5, $6, $7)",
        [
          postgleam.text(message.id),
          postgleam.text(topic.to_string(message.topic)),
          postgleam.int(message.time),
          postgleam.nullable(message.expires, postgleam.int),
          postgleam.bool(message.scheduled),
          postgleam.nullable(message.sequence_id, postgleam.text),
          postgleam.jsonb(payload),
        ],
      ),
    )
    use _ <- result.try(insert_event(tx, state.node_id, message, payload))
    use _ <- result.try(insert_delivery_jobs(tx, jobs))
    use _ <- result.try(notify(tx, message.id))
    Ok(message)
  })
  |> result.map_error(map_error)
}

fn lock_event_commit(
  connection: postgleam.Connection,
) -> Result(Nil, pg_error.Error) {
  postgleam.query(connection, "SELECT pg_advisory_xact_lock($1::bigint)", [
    postgleam.int(event_commit_lock_key),
  ])
  |> result.map(fn(_) { Nil })
}

fn insert_delivery_jobs(
  connection: postgleam.Connection,
  jobs: List(delivery.NewJob),
) -> Result(Nil, pg_error.Error) {
  list.try_each(jobs, fn(job) {
    postgleam.query(
      connection,
      "INSERT INTO notify_delivery_outbox(id, kind, endpoint, payload, message_id, topic_hash, state, attempts, available_at) VALUES ($1, $2, $3, $4, $5, $6, 'pending', 0, $7)",
      [
        postgleam.text(job.id),
        postgleam.text(delivery_kind(job.kind)),
        postgleam.text(job.endpoint),
        postgleam.bytea(job.payload),
        postgleam.text(job.message_id),
        postgleam.text(job.topic_hash),
        postgleam.int(job.available_at),
      ],
    )
    |> result.map(fn(_) { Nil })
  })
}

fn delivery_kind(kind: delivery.Kind) -> String {
  case kind {
    delivery.WebPush -> "webpush"
    delivery.MobileRelay -> "mobile_relay"
  }
}

fn insert_event(
  connection: postgleam.Connection,
  origin_node: String,
  message: Message,
  payload: String,
) -> Result(Nil, pg_error.Error) {
  postgleam.query(
    connection,
    "INSERT INTO notify_event_log(message_id, event, topic, time, origin_node, payload) VALUES ($1, $2, $3, $4, $5, $6)",
    [
      postgleam.text(message.id),
      postgleam.text(message.event |> message.event_to_string),
      postgleam.text(topic.to_string(message.topic)),
      postgleam.int(message.time),
      postgleam.text(origin_node),
      postgleam.jsonb(payload),
    ],
  )
  |> result.map(fn(_) { Nil })
}

fn notify(
  connection: postgleam.Connection,
  payload: String,
) -> Result(Nil, pg_error.Error) {
  postgleam.query(connection, "SELECT pg_notify('notify_events', $1::text)", [
    postgleam.text(payload),
  ])
  |> result.map(fn(_) { Nil })
}

fn run_query(
  state: State,
  selection: Query,
) -> Result(List(Message), storage.Error) {
  case selection.since {
    storage.NoneSince -> Ok([])
    _ -> {
      use cursor <- result.try(initial_query_cursor(state.connection, selection))
      query_pages(state.connection, selection, cursor, [])
    }
  }
}

fn initial_query_cursor(
  connection: postgleam.Connection,
  selection: Query,
) -> Result(Int, storage.Error) {
  case selection.since {
    storage.AfterId(id) ->
      postgleam.query_with(
        connection,
        after_id_cursor_query,
        [
          postgleam.text(id),
          postgleam.jsonb(json_strings(topic.many_to_strings(selection.topics))),
          postgleam.bool(selection.include_scheduled),
        ],
        {
          use position <- decode.element(0, decode.int)
          decode.success(position)
        },
      )
      |> result.map(fn(response) {
        response.rows |> list.first |> result.unwrap(0)
      })
      |> result.map_error(map_error)
    _ -> Ok(0)
  }
}

fn query_pages(
  connection: postgleam.Connection,
  selection: Query,
  cursor: Int,
  pages: List(List(Message)),
) -> Result(List(Message), storage.Error) {
  use response <- result.try(
    postgleam.query_with(
      connection,
      page_query,
      page_parameters(selection, cursor),
      {
        use position <- decode.element(0, decode.int)
        use payload <- decode.element(1, decode.jsonb)
        use scheduled <- decode.element(2, decode.bool)
        decode.success(#(position, payload, scheduled))
      },
    )
    |> result.map_error(map_error),
  )
  use messages <- result.try(
    list.try_map(response.rows, fn(row) {
      use decoded <- result.try(
        json.parse(row.1, message_json.decoder())
        |> result.map_error(fn(_) {
          storage.Corrupt("invalid PostgreSQL message payload")
        }),
      )
      Ok(message.Message(..decoded, scheduled: row.2))
    }),
  )
  let pages = [messages, ..pages]
  case list.length(response.rows) < query_page_size {
    True -> Ok(pages |> list.reverse |> list.flatten)
    False -> {
      let next_cursor =
        response.rows
        |> list.last
        |> result.map(fn(row) { row.0 })
        |> result.unwrap(cursor)
      query_pages(connection, selection, next_cursor, pages)
    }
  }
}

fn page_parameters(selection: Query, cursor: Int) -> List(postgleam.Param) {
  let criteria = selection.criteria
  let #(after_time_enabled, after_time) = case selection.since {
    storage.AfterTime(time) -> #(True, time)
    _ -> #(False, 0)
  }
  [
    postgleam.int(cursor),
    postgleam.jsonb(json_strings(topic.many_to_strings(selection.topics))),
    postgleam.bool(selection.include_scheduled),
    postgleam.bool(after_time_enabled),
    postgleam.int(after_time),
    postgleam.bool(is_some(criteria.id)),
    postgleam.text(optional_string(criteria.id)),
    postgleam.bool(is_some(criteria.message)),
    postgleam.text(optional_string(criteria.message)),
    postgleam.bool(is_some(criteria.title)),
    postgleam.text(optional_string(criteria.title)),
    postgleam.bool(criteria.priorities != []),
    postgleam.jsonb(
      json_ints(list.map(criteria.priorities, message.priority_to_int)),
    ),
    postgleam.jsonb(json_strings(criteria.tags)),
    postgleam.bool(selection.since == storage.Latest),
    postgleam.int(query_page_size),
  ]
}

fn json_strings(values: List(String)) -> String {
  json.array(values, json.string) |> json.to_string
}

fn json_ints(values: List(Int)) -> String {
  json.array(values, json.int) |> json.to_string
}

fn is_some(value: Option(a)) -> Bool {
  case value {
    Some(_) -> True
    None -> False
  }
}

fn optional_string(value: Option(String)) -> String {
  case value {
    Some(value) -> value
    None -> ""
  }
}

fn release_due(
  state: State,
  now: Int,
  limit: Int,
) -> Result(List(Message), storage.Error) {
  postgleam.transaction(state.connection, fn(tx) {
    use _ <- result.try(lock_event_commit(tx))
    use response <- result.try(
      postgleam.query_with(
        tx,
        "WITH due AS (SELECT position FROM notify_messages WHERE scheduled = TRUE AND time <= $1 ORDER BY position ASC FOR UPDATE SKIP LOCKED LIMIT $2) UPDATE notify_messages AS m SET scheduled = FALSE, payload = jsonb_set(m.payload, '{_notify_scheduled}', 'false'::jsonb, TRUE) FROM due WHERE m.position = due.position RETURNING m.payload",
        [postgleam.int(now), postgleam.int(max(0, limit))],
        {
          use payload <- decode.element(0, decode.jsonb)
          decode.success(payload)
        },
      ),
    )
    use messages <- result.try(
      list.try_map(response.rows, fn(payload) {
        case json.parse(payload, message_json.decoder()) {
          Ok(decoded) -> Ok(message.Message(..decoded, scheduled: False))
          Error(_) ->
            Error(postgleam.query_error("invalid scheduled message payload"))
        }
      }),
    )
    use _ <- result.try(
      list.try_each(messages, fn(message) {
        let payload = message_json.encode_storage(message) |> json.to_string
        insert_event(tx, state.node_id, message, payload)
      }),
    )
    use _ <- result.try(case messages {
      [] -> Ok(Nil)
      [first, ..] -> notify(tx, first.id)
    })
    Ok(messages)
  })
  |> result.map_error(map_error)
}

fn cleanup_expired(
  connection: postgleam.Connection,
  now: Int,
) -> Result(Int, storage.Error) {
  postgleam.transaction(connection, fn(tx) {
    use _ <- result.try(
      postgleam.query(
        tx,
        "DELETE FROM notify_node_cursors WHERE updated_at < to_timestamp(extract(epoch from now()) - $1::bigint)",
        [postgleam.int(cluster_health.stale_after_seconds)],
      ),
    )
    use deleted <- result.try(
      postgleam.query_one(
        tx,
        "WITH deleted AS (DELETE FROM notify_messages WHERE (expires IS NOT NULL AND expires <= $1) OR COALESCE((payload->>'_notify_cached')::boolean, TRUE) = FALSE RETURNING 1) SELECT COUNT(*)::bigint FROM deleted",
        [postgleam.int(now)],
        {
          use count <- decode.element(0, decode.int)
          decode.success(count)
        },
      ),
    )
    use _ <- result.try(
      postgleam.query(
        tx,
        "WITH watermark AS (SELECT COALESCE(MIN(sequence), (SELECT COALESCE(MAX(sequence), 0) FROM notify_event_log)) AS sequence FROM notify_node_cursors) DELETE FROM notify_event_log AS event USING watermark WHERE event.sequence <= watermark.sequence AND NOT EXISTS (SELECT 1 FROM notify_messages AS message WHERE message.id = event.message_id)",
        [],
      ),
    )
    Ok(deleted)
  })
  |> result.map_error(map_error)
}

fn stats(
  connection: postgleam.Connection,
) -> Result(storage.Stats, storage.Error) {
  postgleam.query_one(
    connection,
    "SELECT (SELECT COUNT(*)::bigint FROM notify_messages), (SELECT COUNT(*)::bigint FROM notify_messages WHERE scheduled = TRUE), (SELECT COUNT(*)::bigint FROM notify_event_log)",
    [],
    {
      use messages <- decode.element(0, decode.int)
      use scheduled <- decode.element(1, decode.int)
      use events <- decode.element(2, decode.int)
      decode.success(storage.Stats(messages:, scheduled:, events:))
    },
  )
  |> result.map_error(map_error)
}

fn health(connection: postgleam.Connection) -> Result(Nil, storage.Error) {
  postgleam.query(connection, "SELECT 1", [])
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn has_attachment(
  connection: postgleam.Connection,
  attached_topic: topic.Topic,
  key: String,
) -> Result(Bool, storage.Error) {
  let path = "/file/" <> topic.to_string(attached_topic) <> "/" <> key
  postgleam.query_one(
    connection,
    "SELECT EXISTS(SELECT 1 FROM notify_messages WHERE topic = $1 AND (strpos(COALESCE(payload->'attachment'->>'url', ''), $2 || '/') > 0 OR right(COALESCE(payload->'attachment'->>'url', ''), length($2)) = $2))",
    [postgleam.text(topic.to_string(attached_topic)), postgleam.text(path)],
    {
      use found <- decode.element(0, decode.bool)
      decode.success(found)
    },
  )
  |> result.map_error(map_error)
}

fn fetch_events(
  connection: postgleam.Connection,
  node_id: String,
  limit: Int,
) -> Result(List(ClusterEvent), storage.Error) {
  use response <- result.try(
    postgleam.query_with(
      connection,
      "WITH cursor AS (INSERT INTO notify_node_cursors(node_id, sequence) VALUES ($1, 0) ON CONFLICT(node_id) DO UPDATE SET updated_at = now() RETURNING sequence) SELECT event.sequence, event.origin_node, event.payload FROM notify_event_log AS event CROSS JOIN cursor WHERE event.sequence > cursor.sequence ORDER BY event.sequence ASC LIMIT $2",
      [postgleam.text(node_id), postgleam.int(max(1, limit))],
      {
        use sequence <- decode.element(0, decode.int)
        use origin <- decode.element(1, decode.text)
        use payload <- decode.element(2, decode.jsonb)
        decode.success(#(sequence, origin, payload))
      },
    )
    |> result.map_error(map_error),
  )
  list.try_map(response.rows, fn(row) {
    use decoded <- result.try(
      json.parse(row.2, message_json.decoder())
      |> result.map_error(fn(_) {
        storage.Corrupt("invalid cluster event payload")
      }),
    )
    Ok(ClusterEvent(row.0, row.1, decoded))
  })
}

fn ack_events(
  connection: postgleam.Connection,
  node_id: String,
  sequence: Int,
) -> Result(Nil, storage.Error) {
  postgleam.query(
    connection,
    "INSERT INTO notify_node_cursors(node_id, sequence) VALUES ($1, $2) ON CONFLICT(node_id) DO UPDATE SET sequence = GREATEST(notify_node_cursors.sequence, excluded.sequence), updated_at = now()",
    [postgleam.text(node_id), postgleam.int(sequence)],
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn inspect_cluster(
  connection: postgleam.Connection,
  local_node_id: String,
  after: Option(String),
  limit: Int,
) -> Result(cluster_health.Snapshot, storage.Error) {
  let #(after_enabled, after_key) = case after {
    None -> #(False, "")
    Some(value) -> #(True, value)
  }
  postgleam.transaction(connection, fn(tx) {
    use _ <- result.try(postgleam.simple_query(
      tx,
      "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY",
    ))
    use summary <- result.try(
      postgleam.query_one(
        tx,
        "SELECT (SELECT COALESCE(MAX(sequence), 0)::bigint FROM notify_event_log), floor(extract(epoch from now()))::bigint, (SELECT COUNT(*)::bigint FROM notify_node_cursors), (SELECT COUNT(*)::bigint FROM notify_node_cursors WHERE updated_at < to_timestamp(extract(epoch from now()) - $1::bigint))",
        [postgleam.int(cluster_health.stale_after_seconds)],
        {
          use event_head <- decode.element(0, decode.int)
          use database_time <- decode.element(1, decode.int)
          use cursor_count <- decode.element(2, decode.int)
          use stale_nodes <- decode.element(3, decode.int)
          decode.success(#(event_head, database_time, cursor_count, stale_nodes))
        },
      ),
    )
    use response <- result.try(
      postgleam.query_with(
        tx,
        "SELECT node_id, sequence, floor(extract(epoch from updated_at))::bigint, updated_at < to_timestamp(extract(epoch from now()) - $3::bigint) FROM notify_node_cursors WHERE ($1::boolean = FALSE OR node_id > $2) ORDER BY node_id ASC LIMIT $4",
        [
          postgleam.bool(after_enabled),
          postgleam.text(after_key),
          postgleam.int(cluster_health.stale_after_seconds),
          postgleam.int(limit + 1),
        ],
        {
          use node_id <- decode.element(0, decode.text)
          use sequence <- decode.element(1, decode.int)
          use updated_at <- decode.element(2, decode.int)
          use stale <- decode.element(3, decode.bool)
          decode.success(cluster_health.Node(
            node_id:,
            sequence:,
            updated_at:,
            stale:,
          ))
        },
      ),
    )
    Ok(cluster_health.Snapshot(
      local_node_id:,
      event_head: summary.0,
      database_time: summary.1,
      cursor_count: summary.2,
      stale_nodes: summary.3,
      nodes: cluster_health.Page(
        items: list.take(response.rows, limit),
        has_more: list.length(response.rows) > limit,
      ),
    ))
  })
  |> result.map_error(map_error)
}

fn cluster_health_error(error: storage.Error) -> cluster_health.Error {
  case error {
    storage.Corrupt(detail) | storage.UnsupportedSchema(detail) ->
      cluster_health.Corrupt(detail)
    storage.MigrationRequired(version) ->
      cluster_health.Corrupt(
        "PostgreSQL storage migration required at version "
        <> int.to_string(version),
      )
    storage.Conflict(detail) | storage.Unavailable(detail) ->
      cluster_health.Unavailable(detail)
  }
}

fn map_error(error: pg_error.Error) -> storage.Error {
  case error {
    pg_error.PgError(fields, _, _) if fields.code == "23505" ->
      storage.Conflict(fields.message)
    pg_error.PgError(fields, _, _) ->
      storage.Unavailable(
        "PostgreSQL " <> fields.code <> ": " <> fields.message,
      )
    pg_error.ConnectionError(detail)
    | pg_error.AuthenticationError(detail)
    | pg_error.EncodeError(detail)
    | pg_error.ProtocolError(detail)
    | pg_error.SocketError(detail) -> storage.Unavailable(detail)
    pg_error.DecodeError(detail) -> storage.Corrupt(detail)
    pg_error.TimeoutError -> storage.Unavailable("PostgreSQL request timed out")
  }
}

fn max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}
