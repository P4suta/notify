import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
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
  )
}

type State {
  State(connection: postgleam.Connection, node_id: String)
}

type Command {
  Save(Message, Subject(Result(Message, storage.Error)))
  Commit(
    Message,
    List(delivery.NewJob),
    Subject(Result(Message, storage.Error)),
  )
  RunQuery(Query, Subject(Result(List(Message), storage.Error)))
  ReleaseDue(Int, Int, Subject(Result(List(Message), storage.Error)))
  CleanupExpired(Int, Subject(Result(Int, storage.Error)))
  Stats(Subject(Result(storage.Stats, storage.Error)))
  Migrate(Subject(Result(Nil, storage.Error)))
  Health(Subject(Result(Nil, storage.Error)))
  FetchEvents(String, Int, Subject(Result(List(ClusterEvent), storage.Error)))
  AckEvents(String, Int, Subject(Result(Nil, storage.Error)))
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

INSERT INTO notify_schema_migrations(version) VALUES (1)
ON CONFLICT(version) DO NOTHING;
"

const query_page_size = 256

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
  use connection <- result.try(
    postgleam.connect(config) |> result.map_error(map_error),
  )
  case migrate(connection) {
    Error(error) -> {
      postgleam.disconnect(connection)
      Error(error)
    }
    Ok(_) -> start_actor(State(connection:, node_id:))
  }
}

fn start_actor(state: State) -> Result(Adapter, storage.Error) {
  use started <- result.try(
    actor.new(state)
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(fn(_) {
      storage.Unavailable("PostgreSQL storage actor failed to start")
    }),
  )
  let subject = started.data
  let persistent =
    storage.Storage(
      migrate: fn() { process.call(subject, 30_000, Migrate) },
      save: fn(message) {
        process.call(subject, 30_000, fn(reply) { Save(message, reply) })
      },
      query: fn(query) {
        process.call(subject, 30_000, fn(reply) { RunQuery(query, reply) })
      },
      release_due: fn(now, limit) {
        process.call(subject, 30_000, fn(reply) {
          ReleaseDue(now, limit, reply)
        })
      },
      cleanup_expired: fn(now) {
        process.call(subject, 30_000, fn(reply) { CleanupExpired(now, reply) })
      },
      stats: fn() { process.call(subject, 30_000, Stats) },
      health: fn() { process.call(subject, 30_000, Health) },
    )
  Ok(
    Adapter(
      storage: persistent,
      commit: storage.AtomicCommit(fn(message, jobs) {
        process.call(subject, 30_000, fn(reply) { Commit(message, jobs, reply) })
      }),
      fetch_events: fn(node_id, limit) {
        process.call(subject, 30_000, fn(reply) {
          FetchEvents(node_id, limit, reply)
        })
      },
      ack_events: fn(node_id, sequence) {
        process.call(subject, 30_000, fn(reply) {
          AckEvents(node_id, sequence, reply)
        })
      },
    ),
  )
}

fn handle(state: State, command: Command) -> actor.Next(State, Command) {
  case command {
    Save(message, reply) -> respond(state, reply, save(state, message))
    Commit(message, jobs, reply) ->
      respond(state, reply, commit(state, message, jobs))
    RunQuery(query, reply) -> respond(state, reply, run_query(state, query))
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
  }
}

fn respond(
  state: State,
  reply: Subject(a),
  value: a,
) -> actor.Next(State, Command) {
  process.send(reply, value)
  actor.continue(state)
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

fn save(state: State, message: Message) -> Result(Message, storage.Error) {
  commit(state, message, [])
}

fn commit(
  state: State,
  message: Message,
  jobs: List(delivery.NewJob),
) -> Result(Message, storage.Error) {
  let payload = message_json.encode_storage(message) |> json.to_string
  postgleam.transaction(state.connection, fn(tx) {
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
        "DELETE FROM notify_node_cursors WHERE updated_at < now() - INTERVAL '7 days'",
        [],
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

fn fetch_events(
  connection: postgleam.Connection,
  node_id: String,
  limit: Int,
) -> Result(List(ClusterEvent), storage.Error) {
  use _ <- result.try(touch_node_cursor(connection, node_id))
  use cursor <- result.try(node_cursor(connection, node_id))
  use response <- result.try(
    postgleam.query_with(
      connection,
      "SELECT sequence, origin_node, payload FROM notify_event_log WHERE sequence > $1 ORDER BY sequence ASC LIMIT $2",
      [postgleam.int(cursor), postgleam.int(max(1, limit))],
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

fn touch_node_cursor(
  connection: postgleam.Connection,
  node_id: String,
) -> Result(Nil, storage.Error) {
  postgleam.query(
    connection,
    "INSERT INTO notify_node_cursors(node_id, sequence) VALUES ($1, 0) ON CONFLICT(node_id) DO UPDATE SET updated_at = now()",
    [postgleam.text(node_id)],
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn node_cursor(
  connection: postgleam.Connection,
  node_id: String,
) -> Result(Int, storage.Error) {
  use response <- result.try(
    postgleam.query_with(
      connection,
      "SELECT sequence FROM notify_node_cursors WHERE node_id = $1",
      [postgleam.text(node_id)],
      {
        use sequence <- decode.element(0, decode.int)
        decode.success(sequence)
      },
    )
    |> result.map_error(map_error),
  )
  Ok(response.rows |> list.first |> result.unwrap(0))
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
