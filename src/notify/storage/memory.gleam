import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/result
import notify/core/message.{type Message}
import notify/storage.{type Query, type Storage}

type Command {
  Save(Message, Subject(Result(Message, storage.Error)))
  RunQuery(Query, Subject(Result(List(Message), storage.Error)))
  ReleaseDue(Int, Int, Subject(Result(List(Message), storage.Error)))
  CleanupExpired(Int, Subject(Result(Int, storage.Error)))
  Stats(Subject(Result(storage.Stats, storage.Error)))
  Migrate(Subject(Result(Nil, storage.Error)))
  Health(Subject(Result(Nil, storage.Error)))
}

pub fn start() -> Result(Storage, actor.StartError) {
  use started <- result.try(
    actor.new([])
    |> actor.on_message(handle)
    |> actor.start,
  )
  let subject = started.data
  Ok(
    storage.Storage(
      migrate: fn() { process.call(subject, 5000, Migrate) },
      save: fn(message) {
        process.call(subject, 5000, fn(reply) { Save(message, reply) })
      },
      query: fn(query) {
        process.call(subject, 5000, fn(reply) { RunQuery(query, reply) })
      },
      release_due: fn(now, limit) {
        process.call(subject, 5000, fn(reply) { ReleaseDue(now, limit, reply) })
      },
      cleanup_expired: fn(now) {
        process.call(subject, 5000, fn(reply) { CleanupExpired(now, reply) })
      },
      stats: fn() { process.call(subject, 5000, Stats) },
      health: fn() { process.call(subject, 5000, Health) },
    ),
  )
}

fn handle(
  messages: List(Message),
  command: Command,
) -> actor.Next(List(Message), Command) {
  case command {
    Save(message, reply) -> {
      process.send(reply, Ok(message))
      actor.continue(list.append(messages, [message]))
    }
    RunQuery(query, reply) -> {
      process.send(reply, Ok(storage.apply_query(messages, query)))
      actor.continue(messages)
    }
    ReleaseDue(now, limit, reply) -> {
      let #(updated, released) = release(messages, now, max(0, limit), [], [])
      process.send(reply, Ok(released))
      actor.continue(updated)
    }
    CleanupExpired(now, reply) -> {
      let remaining =
        list.filter(messages, fn(message) {
          case message.cached, message.expires {
            False, _ -> False
            True, option.Some(expires) -> expires > now
            True, option.None -> True
          }
        })
      process.send(reply, Ok(list.length(messages) - list.length(remaining)))
      actor.continue(remaining)
    }
    Stats(reply) -> {
      process.send(
        reply,
        Ok(storage.Stats(
          messages: list.length(messages),
          scheduled: messages
            |> list.filter(fn(message) { message.scheduled })
            |> list.length,
          events: list.length(messages),
        )),
      )
      actor.continue(messages)
    }
    Migrate(reply) | Health(reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(messages)
    }
  }
}

fn release(
  messages: List(Message),
  now: Int,
  remaining: Int,
  updated: List(Message),
  released: List(Message),
) -> #(List(Message), List(Message)) {
  case messages {
    [] -> #(list.reverse(updated), list.reverse(released))
    [item, ..rest] ->
      case item.scheduled && item.time <= now && remaining > 0 {
        False -> release(rest, now, remaining, [item, ..updated], released)
        True -> {
          let due = message.Message(..item, scheduled: False)
          release(rest, now, remaining - 1, [due, ..updated], [due, ..released])
        }
      }
  }
}

fn max(a: Int, b: Int) -> Int {
  case a > b {
    True -> a
    False -> b
  }
}
