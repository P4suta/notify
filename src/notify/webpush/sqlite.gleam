import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import notify/webpush.{type Store, type Subscription}
import sqlight.{type Connection}

type State {
  State(connection: Connection, max_endpoints_per_ip: Int)
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

type SubscriptionTopicRow {
  SubscriptionTopicRow(subscription: Subscription, topic: Option(String))
}

const migration = "
PRAGMA journal_mode=WAL;
PRAGMA foreign_keys=ON;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS webpush_subscriptions (
  id TEXT PRIMARY KEY,
  endpoint TEXT NOT NULL UNIQUE,
  key_auth TEXT NOT NULL,
  key_p256dh TEXT NOT NULL,
  user_id TEXT NOT NULL DEFAULT '',
  subscriber_ip TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS webpush_subscriptions_ip
  ON webpush_subscriptions(subscriber_ip);
CREATE INDEX IF NOT EXISTS webpush_subscriptions_expiry
  ON webpush_subscriptions(updated_at);
CREATE INDEX IF NOT EXISTS webpush_subscriptions_user
  ON webpush_subscriptions(user_id);

CREATE TABLE IF NOT EXISTS webpush_topics (
  subscription_id TEXT NOT NULL,
  topic TEXT NOT NULL,
  PRIMARY KEY(subscription_id, topic),
  FOREIGN KEY(subscription_id) REFERENCES webpush_subscriptions(id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS webpush_topics_topic ON webpush_topics(topic);
"

pub fn start(
  path: String,
  max_endpoints_per_ip limit: Int,
) -> Result(Store, webpush.Error) {
  use connection <- result.try(
    sqlight.open(path) |> result.map_error(map_error),
  )
  case sqlight.exec(migration, connection) {
    Error(error) -> {
      let _ = sqlight.close(connection)
      Error(map_error(error))
    }
    Ok(_) ->
      start_actor(State(connection:, max_endpoints_per_ip: max(1, limit)))
  }
}

/// Creates or upgrades only the Web Push schema and closes the connection.
/// This is intended for offline, transactional maintenance commands.
pub fn prepare(path: String) -> Result(Nil, webpush.Error) {
  use connection <- result.try(
    sqlight.open(path) |> result.map_error(map_error),
  )
  let migrated =
    sqlight.exec(migration, connection) |> result.map_error(map_error)
  let _ = sqlight.close(connection)
  migrated
}

fn start_actor(state: State) -> Result(Store, webpush.Error) {
  use started <- result.try(
    actor.new(state)
    |> actor.on_message(handle)
    |> actor.start
    |> result.map_error(fn(_) {
      webpush.Unavailable("SQLite Web Push actor failed to start")
    }),
  )
  let subject = started.data
  Ok(
    webpush.Store(
      upsert: fn(value) {
        process.call(subject, 10_000, fn(reply) { Upsert(value, reply) })
      },
      for_topic: fn(topic) {
        process.call(subject, 10_000, fn(reply) { ForTopic(topic, reply) })
      },
      by_endpoint: fn(endpoint) {
        process.call(subject, 10_000, fn(reply) { ByEndpoint(endpoint, reply) })
      },
      remove_endpoint: fn(endpoint) {
        process.call(subject, 10_000, fn(reply) {
          RemoveEndpoint(endpoint, reply)
        })
      },
      remove_user: fn(user_id) {
        process.call(subject, 10_000, fn(reply) { RemoveUser(user_id, reply) })
      },
      remove_expired: fn(before) {
        process.call(subject, 10_000, fn(reply) { RemoveExpired(before, reply) })
      },
      health: fn() { process.call(subject, 10_000, Health) },
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
  transaction(state.connection, fn() {
    case by_endpoint(state.connection, value.endpoint) {
      Error(webpush.NotFound) -> {
        use count <- result.try(subscription_count_for_ip(
          state.connection,
          value.subscriber_ip,
        ))
        case count >= state.max_endpoints_per_ip {
          True -> Error(webpush.TooManySubscriptions)
          False ->
            insert_subscription(state.connection, webpush.from_new(value))
        }
      }
      Error(error) -> Error(error)
      Ok(previous) -> {
        let candidate = webpush.from_new(value)
        update_subscription(
          state.connection,
          webpush.Subscription(
            ..candidate,
            id: previous.id,
            created_at: previous.created_at,
          ),
        )
      }
    }
  })
}

fn insert_subscription(
  connection: Connection,
  subscription: Subscription,
) -> Result(Subscription, webpush.Error) {
  use _ <- result.try(
    sqlight.query(
      "INSERT INTO webpush_subscriptions(id, endpoint, key_auth, key_p256dh, user_id, subscriber_ip, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
      on: connection,
      with: subscription_params(subscription),
      expecting: decode.dynamic,
    )
    |> result.map_error(map_error),
  )
  use _ <- result.try(replace_topics(connection, subscription))
  Ok(subscription)
}

fn update_subscription(
  connection: Connection,
  subscription: Subscription,
) -> Result(Subscription, webpush.Error) {
  use _ <- result.try(
    sqlight.query(
      "UPDATE webpush_subscriptions SET key_auth = ?, key_p256dh = ?, user_id = ?, subscriber_ip = ?, updated_at = ? WHERE id = ?",
      on: connection,
      with: [
        sqlight.text(subscription.auth),
        sqlight.text(subscription.p256dh),
        sqlight.text(webpush.user_id_string(subscription.user_id)),
        sqlight.text(subscription.subscriber_ip),
        sqlight.int(subscription.updated_at),
        sqlight.text(subscription.id),
      ],
      expecting: decode.dynamic,
    )
    |> result.map_error(map_error),
  )
  use _ <- result.try(replace_topics(connection, subscription))
  Ok(subscription)
}

fn subscription_params(subscription: Subscription) -> List(sqlight.Value) {
  [
    sqlight.text(subscription.id),
    sqlight.text(subscription.endpoint),
    sqlight.text(subscription.auth),
    sqlight.text(subscription.p256dh),
    sqlight.text(webpush.user_id_string(subscription.user_id)),
    sqlight.text(subscription.subscriber_ip),
    sqlight.int(subscription.created_at),
    sqlight.int(subscription.updated_at),
  ]
}

fn replace_topics(
  connection: Connection,
  subscription: Subscription,
) -> Result(Nil, webpush.Error) {
  use _ <- result.try(
    sqlight.query(
      "DELETE FROM webpush_topics WHERE subscription_id = ?",
      on: connection,
      with: [sqlight.text(subscription.id)],
      expecting: decode.dynamic,
    )
    |> result.map_error(map_error),
  )
  subscription.topics
  |> list.try_each(fn(topic) {
    sqlight.query(
      "INSERT INTO webpush_topics(subscription_id, topic) VALUES (?, ?)",
      on: connection,
      with: [sqlight.text(subscription.id), sqlight.text(topic)],
      expecting: decode.dynamic,
    )
    |> result.map(fn(_) { Nil })
    |> result.map_error(map_error)
  })
}

fn for_topic(
  connection: Connection,
  topic: String,
) -> Result(List(Subscription), webpush.Error) {
  use rows <- result.try(
    sqlight.query(
      "SELECT s.id, s.endpoint, s.key_auth, s.key_p256dh, s.user_id, s.subscriber_ip, s.created_at, s.updated_at, all_topics.topic FROM webpush_subscriptions s JOIN webpush_topics matched ON matched.subscription_id = s.id AND matched.topic = ? LEFT JOIN webpush_topics all_topics ON all_topics.subscription_id = s.id ORDER BY s.endpoint, all_topics.rowid",
      on: connection,
      with: [sqlight.text(topic)],
      expecting: subscription_topic_decoder(),
    )
    |> result.map_error(map_error),
  )
  Ok(group_subscription_topics(rows, []))
}

fn by_endpoint(
  connection: Connection,
  endpoint: String,
) -> Result(Subscription, webpush.Error) {
  use rows <- result.try(
    sqlight.query(
      "SELECT s.id, s.endpoint, s.key_auth, s.key_p256dh, s.user_id, s.subscriber_ip, s.created_at, s.updated_at, topics.topic FROM webpush_subscriptions s LEFT JOIN webpush_topics topics ON topics.subscription_id = s.id WHERE s.endpoint = ? ORDER BY topics.rowid",
      on: connection,
      with: [sqlight.text(endpoint)],
      expecting: subscription_topic_decoder(),
    )
    |> result.map_error(map_error),
  )
  case group_subscription_topics(rows, []) {
    [subscription] -> Ok(subscription)
    [] -> Error(webpush.NotFound)
    _ -> Error(webpush.Unavailable("duplicate Web Push endpoint"))
  }
}

fn group_subscription_topics(
  rows: List(SubscriptionTopicRow),
  accumulated: List(Subscription),
) -> List(Subscription) {
  case rows {
    [] -> list.reverse(accumulated)
    [SubscriptionTopicRow(subscription, topic), ..remaining] -> {
      let initial_topics = case topic {
        None -> []
        Some(topic) -> [topic]
      }
      let #(topics, remaining) =
        take_subscription_topics(
          remaining,
          subscription.id,
          list.reverse(initial_topics),
        )
      group_subscription_topics(remaining, [
        webpush.Subscription(..subscription, topics:),
        ..accumulated
      ])
    }
  }
}

fn take_subscription_topics(
  rows: List(SubscriptionTopicRow),
  subscription_id: String,
  reversed_topics: List(String),
) -> #(List(String), List(SubscriptionTopicRow)) {
  case rows {
    [SubscriptionTopicRow(subscription, topic), ..remaining]
      if subscription.id == subscription_id
    -> {
      let reversed_topics = case topic {
        None -> reversed_topics
        Some(topic) -> [topic, ..reversed_topics]
      }
      take_subscription_topics(remaining, subscription_id, reversed_topics)
    }
    _ -> #(list.reverse(reversed_topics), rows)
  }
}

fn subscription_count_for_ip(
  connection: Connection,
  subscriber_ip: String,
) -> Result(Int, webpush.Error) {
  use counts <- result.try(
    sqlight.query(
      "SELECT COUNT(*) FROM webpush_subscriptions WHERE subscriber_ip = ?",
      on: connection,
      with: [sqlight.text(subscriber_ip)],
      expecting: {
        use count <- decode.field(0, decode.int)
        decode.success(count)
      },
    )
    |> result.map_error(map_error),
  )
  case counts {
    [count] -> Ok(count)
    _ -> Error(webpush.Unavailable("Web Push count query failed"))
  }
}

fn remove_endpoint(
  connection: Connection,
  endpoint: String,
) -> Result(Nil, webpush.Error) {
  sqlight.query(
    "DELETE FROM webpush_subscriptions WHERE endpoint = ?",
    on: connection,
    with: [sqlight.text(endpoint)],
    expecting: decode.dynamic,
  )
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn remove_user(
  connection: Connection,
  user_id: String,
) -> Result(Int, webpush.Error) {
  remove_counted(
    connection,
    "SELECT COUNT(*) FROM webpush_subscriptions WHERE user_id = ?",
    "DELETE FROM webpush_subscriptions WHERE user_id = ?",
    sqlight.text(user_id),
  )
}

fn remove_expired(
  connection: Connection,
  before: Int,
) -> Result(Int, webpush.Error) {
  remove_counted(
    connection,
    "SELECT COUNT(*) FROM webpush_subscriptions WHERE updated_at <= ?",
    "DELETE FROM webpush_subscriptions WHERE updated_at <= ?",
    sqlight.int(before),
  )
}

fn remove_counted(
  connection: Connection,
  count_sql: String,
  delete_sql: String,
  parameter: sqlight.Value,
) -> Result(Int, webpush.Error) {
  transaction(connection, fn() {
    use counts <- result.try(
      sqlight.query(count_sql, on: connection, with: [parameter], expecting: {
        use count <- decode.field(0, decode.int)
        decode.success(count)
      })
      |> result.map_error(map_error),
    )
    use count <- result.try(case counts {
      [count] -> Ok(count)
      _ -> Error(webpush.Unavailable("Web Push count query failed"))
    })
    use _ <- result.try(
      sqlight.query(
        delete_sql,
        on: connection,
        with: [parameter],
        expecting: decode.dynamic,
      )
      |> result.map_error(map_error),
    )
    Ok(count)
  })
}

fn subscription_topic_decoder() -> decode.Decoder(SubscriptionTopicRow) {
  use id <- decode.field(0, decode.string)
  use endpoint <- decode.field(1, decode.string)
  use auth <- decode.field(2, decode.string)
  use p256dh <- decode.field(3, decode.string)
  use user_id <- decode.field(4, decode.string)
  use subscriber_ip <- decode.field(5, decode.string)
  use created_at <- decode.field(6, decode.int)
  use updated_at <- decode.field(7, decode.int)
  use topic <- decode.field(8, decode.optional(decode.string))
  decode.success(SubscriptionTopicRow(
    subscription: webpush.Subscription(
      id:,
      endpoint:,
      auth:,
      p256dh:,
      topics: [],
      user_id: webpush.optional_user_id(user_id),
      subscriber_ip:,
      created_at:,
      updated_at:,
    ),
    topic:,
  ))
}

fn transaction(
  connection: Connection,
  work: fn() -> Result(a, webpush.Error),
) -> Result(a, webpush.Error) {
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

fn health(connection: Connection) -> Result(Nil, webpush.Error) {
  sqlight.query("SELECT 1", on: connection, with: [], expecting: decode.dynamic)
  |> result.map(fn(_) { Nil })
  |> result.map_error(map_error)
}

fn map_error(error: sqlight.Error) -> webpush.Error {
  let sqlight.SqlightError(code:, message:, ..) = error
  case code {
    sqlight.Constraint | sqlight.ConstraintUnique -> webpush.Conflict
    _ -> webpush.Unavailable(message)
  }
}

fn max(first: Int, second: Int) -> Int {
  case first > second {
    True -> first
    False -> second
  }
}
