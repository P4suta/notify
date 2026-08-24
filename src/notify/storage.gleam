import gleam/list
import gleam/option
import notify/core/filter.{type Criteria}
import notify/core/message.{type Message}
import notify/core/topic.{type Topic}
import notify/delivery

pub type Since {
  NoneSince
  All
  Latest
  AfterTime(Int)
  AfterId(String)
}

pub type Query {
  Query(
    topics: List(Topic),
    since: Since,
    include_scheduled: Bool,
    criteria: Criteria,
  )
}

pub type Error {
  Unavailable(String)
  Conflict(String)
  Corrupt(String)
  MigrationRequired(Int)
}

pub type Stats {
  Stats(messages: Int, scheduled: Int, events: Int)
}

/// Adapter capability for committing a message, its event-log row, and all
/// delivery jobs in one database transaction.
pub type AtomicCommit {
  AtomicCommit(
    run: fn(Message, List(delivery.NewJob)) -> Result(Message, Error),
  )
}

/// The persistence boundary. `save` must commit both the message and its event-log
/// entry before returning `Ok`; callers only fan out after that point.
pub type Storage {
  Storage(
    migrate: fn() -> Result(Nil, Error),
    save: fn(Message) -> Result(Message, Error),
    query: fn(Query) -> Result(List(Message), Error),
    release_due: fn(Int, Int) -> Result(List(Message), Error),
    cleanup_expired: fn(Int) -> Result(Int, Error),
    stats: fn() -> Result(Stats, Error),
    health: fn() -> Result(Nil, Error),
  )
}

/// Shared selection semantics used by every adapter's contract suite.
pub fn apply_query(messages: List(Message), query: Query) -> List(Message) {
  let selected =
    messages
    |> list.filter(fn(message) {
      list.contains(query.topics, message.topic)
      && message.cached
      && case query.since, message.scheduled {
        Latest, True -> False
        _, _ -> True
      }
      && case query.include_scheduled, message.scheduled {
        True, _ | False, False -> True
        False, True -> False
      }
    })
    |> apply_since(query.since)

  list.filter(selected, fn(message) { filter.matches(message, query.criteria) })
}

fn apply_since(messages: List(Message), since: Since) -> List(Message) {
  case since {
    NoneSince -> []
    All -> messages
    Latest -> latest_per_topic(messages)
    AfterTime(time) ->
      list.filter(messages, fn(message) { message.time >= time })
    AfterId(id) -> after_id(messages, id) |> option.unwrap(messages)
  }
}

fn after_id(
  messages: List(Message),
  id: String,
) -> option.Option(List(Message)) {
  case messages {
    [] -> option.None
    [message, ..rest] ->
      case message.id == id {
        True -> option.Some(rest)
        False -> after_id(rest, id)
      }
  }
}

fn latest_per_topic(messages: List(Message)) -> List(Message) {
  case messages {
    [] -> []
    [message, ..rest] ->
      case list.any(rest, fn(later) { later.topic == message.topic }) {
        True -> latest_per_topic(rest)
        False -> [message, ..latest_per_topic(rest)]
      }
  }
}
