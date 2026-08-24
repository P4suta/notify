import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result
import notify/webpush.{type Store, type Subscription}
import postgleam
import postgleam/config.{type Config}
import postgleam/decode
import postgleam/error as pg_error

type State {
  State(connection: postgleam.Connection, max_endpoints_per_ip: Int)
}

type Command {
  Upsert(webpush.NewSubscription, Subject(Result(Subscription, webpush.Error)))
  ForTopic(String, Subject(Result(List(Subscription), webpush.Error)))
  ByEndpoint(String, Subject(Result(Subscription, webpush.Error)))
  RemoveEndpoint(String, Subject(Result(Nil, webpush.Error)))
  RemoveUser(String, Subject(Result(Int, webpush.Error)))
  RemoveExpired(Int, Subject(Result(Int, webpush.Error)))
  Health(Subject(Result(Nil, webpush.Error)))
}

const migration = "
CREATE TABLE IF NOT EXISTS notify_webpush_subscriptions (
  id TEXT PRIMARY KEY,
  endpoint TEXT NOT NULL UNIQUE,
  key_auth TEXT NOT NULL,
  key_p256dh TEXT NOT NULL,
  user_id TEXT NOT NULL DEFAULT '',
  subscriber_ip TEXT NOT NULL,
  created_at BIGINT NOT NULL,
  updated_at BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS notify_webpush_subscriptions_ip
  ON notify_webpush_subscriptions(subscriber_ip);
CREATE INDEX IF NOT EXISTS notify_webpush_subscriptions_expiry
  ON notify_webpush_subscriptions(updated_at);
CREATE INDEX IF NOT EXISTS notify_webpush_subscriptions_user
  ON notify_webpush_subscriptions(user_id);

CREATE TABLE IF NOT EXISTS notify_webpush_topics (
  subscription_id TEXT NOT NULL REFERENCES notify_webpush_subscriptions(id) ON DELETE CASCADE,
  topic TEXT NOT NULL,
  position BIGINT NOT NULL,
  PRIMARY KEY(subscription_id, topic)
);
CREATE INDEX IF NOT EXISTS notify_webpush_topics_topic
  ON notify_webpush_topics(topic);
"

pub fn start(
  config: Config,
  max_endpoints_per_ip limit: Int,
) -> Result(Store, webpush.Error) {
  use connection <- result.try(
    postgleam.connect(config) |> result.map_error(map_error),
  )
  case migrate(connection) {
    Error(error) -> {
      postgleam.disconnect(connection)
      Error(error)
    }
    Ok(_) ->
      start_actor(State(connection:, max_endpoints_per_ip: max(1, limit)))
  }
}

fn migrate(connection: postgleam.Connection) -> Result(Nil, webpush.Error) {
  postgleam.transaction(connection, fn(tx) {
    use _ <- result.try(
      postgleam.query(tx, "SELECT pg_advisory_xact_lock($1::bigint)", [
        postgleam.int(7_413_706_846),
      ]),
    )
    use _ <- result.try(postgleam.simple_query(tx, migration))
    Ok(Nil)
  })
  |> result.map_error(map_error)
}

fn start_actor(state: State) -> Result(Store, webpush.Error) {
  use started <- result.try(
    actor.new(state)
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(fn(_) {
      webpush.Unavailable("PostgreSQL Web Push actor failed to start")
    }),
  )
  let subject = started.data
  Ok(
    webpush.Store(
      upsert: fn(value) {
        process.call(subject, 30_000, fn(reply) { Upsert(value, reply) })
      },
      for_topic: fn(topic) {
        process.call(subject, 30_000, fn(reply) { ForTopic(topic, reply) })
      },
      by_endpoint: fn(endpoint) {
        process.call(subject, 30_000, fn(reply) { ByEndpoint(endpoint, reply) })
      },
      remove_endpoint: fn(endpoint) {
        process.call(subject, 30_000, fn(reply) {
          RemoveEndpoint(endpoint, reply)
        })
      },
      remove_user: fn(user_id) {
        process.call(subject, 30_000, fn(reply) { RemoveUser(user_id, reply) })
      },
      remove_expired: fn(before) {
        process.call(subject, 30_000, fn(reply) { RemoveExpired(before, reply) })
      },
      health: fn() { process.call(subject, 30_000, Health) },
    ),
  )
}

fn handle(state: State, command: Command) -> actor.Next(State, Command) {
  case command {
    Upsert(value, reply) -> process.send(reply, upsert(state, value))
    ForTopic(topic, reply) ->
      process.send(reply, for_topic(state.connection, topic))
    ByEndpoint(endpoint, reply) ->
      process.send(reply, by_endpoint(state.connection, endpoint))
    RemoveEndpoint(endpoint, reply) ->
      process.send(reply, remove_endpoint(state.connection, endpoint))
    RemoveUser(user_id, reply) ->
      process.send(reply, remove_user(state.connection, user_id))
    RemoveExpired(before, reply) ->
      process.send(reply, remove_expired(state.connection, before))
    Health(reply) -> process.send(reply, health(state.connection))
  }
  actor.continue(state)
}

fn upsert(
  state: State,
  value: webpush.NewSubscription,
) -> Result(Subscription, webpush.Error) {
  use _ <- result.try(webpush.validate(value))
  postgleam.transaction(state.connection, fn(tx) {
    use _ <- result.try(
      postgleam.query(tx, "SELECT pg_advisory_xact_lock($1::bigint)", [
        postgleam.int(7_413_706_847),
      ]),
    )
    use existing <- result.try(postgleam.query_with(
      tx,
      "SELECT id, endpoint, key_auth, key_p256dh, user_id, subscriber_ip, created_at, updated_at FROM notify_webpush_subscriptions WHERE endpoint = $1 FOR UPDATE",
      [postgleam.text(value.endpoint)],
      subscription_decoder(),
    ))
    let candidate = webpush.from_new(value)
    let subscription = case existing.rows {
      [] -> candidate
      [previous] ->
        webpush.Subscription(
          ..candidate,
          id: previous.id,
          created_at: previous.created_at,
        )
      _ -> candidate
    }
    case existing.rows {
      [] -> {
        use count <- result.try(
          postgleam.query_one(
            tx,
            "SELECT COUNT(*)::bigint FROM notify_webpush_subscriptions WHERE subscriber_ip = $1",
            [postgleam.text(value.subscriber_ip)],
            {
              use count <- decode.element(0, decode.int)
              decode.success(count)
            },
          ),
        )
        case count >= state.max_endpoints_per_ip {
          True -> Error(postgleam.query_error("webpush quota exceeded"))
          False -> insert_subscription(tx, subscription)
        }
      }
      [_] -> update_subscription(tx, subscription)
      _ -> Error(postgleam.query_error("duplicate Web Push endpoint"))
    }
  })
  |> result.map_error(fn(error) {
    case error {
      pg_error.ConnectionError("webpush quota exceeded") ->
        webpush.TooManySubscriptions
      other -> map_error(other)
    }
  })
}

fn insert_subscription(
  connection: postgleam.Connection,
  subscription: Subscription,
) -> Result(Subscription, pg_error.Error) {
  use _ <- result.try(postgleam.query(
    connection,
    "INSERT INTO notify_webpush_subscriptions(id, endpoint, key_auth, key_p256dh, user_id, subscriber_ip, created_at, updated_at) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
    subscription_params(subscription),
  ))
  use _ <- result.try(replace_topics(connection, subscription))
  Ok(subscription)
}

fn update_subscription(
  connection: postgleam.Connection,
  subscription: Subscription,
) -> Result(Subscription, pg_error.Error) {
  use _ <- result.try(
    postgleam.query(
      connection,
      "UPDATE notify_webpush_subscriptions SET key_auth = $1, key_p256dh = $2, user_id = $3, subscriber_ip = $4, updated_at = $5 WHERE id = $6",
      [
        postgleam.text(subscription.auth),
        postgleam.text(subscription.p256dh),
        postgleam.text(webpush.user_id_string(subscription.user_id)),
        postgleam.text(subscription.subscriber_ip),
        postgleam.int(subscription.updated_at),
        postgleam.text(subscription.id),
      ],
    ),
  )
  use _ <- result.try(replace_topics(connection, subscription))
  Ok(subscription)
}

fn subscription_params(subscription: Subscription) -> List(postgleam.Param) {
  [
    postgleam.text(subscription.id),
    postgleam.text(subscription.endpoint),
    postgleam.text(subscription.auth),
    postgleam.text(subscription.p256dh),
    postgleam.text(webpush.user_id_string(subscription.user_id)),
    postgleam.text(subscription.subscriber_ip),
    postgleam.int(subscription.created_at),
    postgleam.int(subscription.updated_at),
  ]
}

fn replace_topics(
  connection: postgleam.Connection,
  subscription: Subscription,
) -> Result(Nil, pg_error.Error) {
  use _ <- result.try(
    postgleam.query(
      connection,
      "DELETE FROM notify_webpush_topics WHERE subscription_id = $1",
      [postgleam.text(subscription.id)],
    ),
  )
  subscription.topics
  |> list.index_map(fn(topic, index) { #(topic, index) })
  |> list.try_each(fn(pair) {
    postgleam.query(
      connection,
      "INSERT INTO notify_webpush_topics(subscription_id, topic, position) VALUES ($1, $2, $3)",
      [
        postgleam.text(subscription.id),
        postgleam.text(pair.0),
        postgleam.int(pair.1),
      ],
    )
    |> result.map(fn(_) { Nil })
  })
}

fn for_topic(
  connection: postgleam.Connection,
  topic: String,
) -> Result(List(Subscription), webpush.Error) {
  use response <- result.try(
    postgleam.query_with(
      connection,
      "SELECT s.id, s.endpoint, s.key_auth, s.key_p256dh, s.user_id, s.subscriber_ip, s.created_at, s.updated_at FROM notify_webpush_subscriptions s JOIN notify_webpush_topics t ON t.subscription_id = s.id WHERE t.topic = $1 ORDER BY s.endpoint",
      [postgleam.text(topic)],
      subscription_decoder(),
    )
    |> result.map_error(map_error),
  )
  list.try_map(response.rows, fn(subscription) {
    with_topics(connection, subscription)
  })
}

fn by_endpoint(
  connection: postgleam.Connection,
  endpoint: String,
) -> Result(Subscription, webpush.Error) {
  use response <- result.try(
    postgleam.query_with(
      connection,
      "SELECT id, endpoint, key_auth, key_p256dh, user_id, subscriber_ip, created_at, updated_at FROM notify_webpush_subscriptions WHERE endpoint = $1",
      [postgleam.text(endpoint)],
      subscription_decoder(),
    )
    |> result.map_error(map_error),
  )
  case response.rows {
    [subscription] -> with_topics(connection, subscription)
    [] -> Error(webpush.NotFound)
    _ -> Error(webpush.Unavailable("duplicate Web Push endpoint"))
  }
}

fn with_topics(
  connection: postgleam.Connection,
  subscription: Subscription,
) -> Result(Subscription, webpush.Error) {
  use response <- result.try(
    postgleam.query_with(
      connection,
      "SELECT topic FROM notify_webpush_topics WHERE subscription_id = $1 ORDER BY position",
      [postgleam.text(subscription.id)],
      {
        use topic <- decode.element(0, decode.text)
        decode.success(topic)
      },
    )
    |> result.map_error(map_error),
  )
  Ok(webpush.Subscription(..subscription, topics: response.rows))
}

fn remove_endpoint(
  connection: postgleam.Connection,
  endpoint: String,
) -> Result(Nil, webpush.Error) {
  postgleam.query(
    connection,
    "DELETE FROM notify_webpush_subscriptions WHERE endpoint = $1",
    [postgleam.text(endpoint)],
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn remove_user(
  connection: postgleam.Connection,
  user_id: String,
) -> Result(Int, webpush.Error) {
  postgleam.query_one(
    connection,
    "WITH deleted AS (DELETE FROM notify_webpush_subscriptions WHERE user_id = $1 RETURNING 1) SELECT COUNT(*)::bigint FROM deleted",
    [postgleam.text(user_id)],
    {
      use count <- decode.element(0, decode.int)
      decode.success(count)
    },
  )
  |> result.map_error(map_error)
}

fn remove_expired(
  connection: postgleam.Connection,
  before: Int,
) -> Result(Int, webpush.Error) {
  postgleam.query_one(
    connection,
    "WITH deleted AS (DELETE FROM notify_webpush_subscriptions WHERE updated_at <= $1 RETURNING 1) SELECT COUNT(*)::bigint FROM deleted",
    [postgleam.int(before)],
    {
      use count <- decode.element(0, decode.int)
      decode.success(count)
    },
  )
  |> result.map_error(map_error)
}

fn subscription_decoder() -> decode.RowDecoder(Subscription) {
  use id <- decode.element(0, decode.text)
  use endpoint <- decode.element(1, decode.text)
  use auth <- decode.element(2, decode.text)
  use p256dh <- decode.element(3, decode.text)
  use user_id <- decode.element(4, decode.text)
  use subscriber_ip <- decode.element(5, decode.text)
  use created_at <- decode.element(6, decode.int)
  use updated_at <- decode.element(7, decode.int)
  decode.success(webpush.Subscription(
    id:,
    endpoint:,
    auth:,
    p256dh:,
    topics: [],
    user_id: webpush.optional_user_id(user_id),
    subscriber_ip:,
    created_at:,
    updated_at:,
  ))
}

fn health(connection: postgleam.Connection) -> Result(Nil, webpush.Error) {
  postgleam.query(connection, "SELECT 1", [])
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn map_error(error: pg_error.Error) -> webpush.Error {
  case error {
    pg_error.PgError(fields, _, _) -> {
      case fields.code {
        "23505" -> webpush.Conflict
        _ ->
          webpush.Unavailable(
            "PostgreSQL " <> fields.code <> ": " <> fields.message,
          )
      }
    }
    pg_error.ConnectionError(detail)
    | pg_error.AuthenticationError(detail)
    | pg_error.EncodeError(detail)
    | pg_error.DecodeError(detail)
    | pg_error.ProtocolError(detail)
    | pg_error.SocketError(detail) -> webpush.Unavailable(detail)
    pg_error.TimeoutError -> webpush.Unavailable("PostgreSQL request timed out")
  }
}

fn max(first: Int, second: Int) -> Int {
  case first > second {
    True -> first
    False -> second
  }
}
