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

type State {
  State(messages: List(Message), events: Int)
}

pub fn start() -> Result(Storage, actor.StartError) {
  use started <- result.try(
    actor.new(State(messages: [], events: 0))
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

fn handle(state: State, command: Command) -> actor.Next(State, Command) {
  case command {
    Save(message, reply) -> {
      process.send(reply, Ok(message))
      actor.continue(State(
        messages: list.append(state.messages, [message]),
        events: state.events + 1,
      ))
    }
    RunQuery(query, reply) -> {
      process.send(reply, Ok(storage.apply_query(state.messages, query)))
      actor.continue(state)
    }
    ReleaseDue(now, limit, reply) -> {
      let #(updated, released) =
        release(state.messages, now, max(0, limit), [], [])
      process.send(reply, Ok(released))
      actor.continue(State(
        messages: updated,
        events: state.events + list.length(released),
      ))
    }
    CleanupExpired(now, reply) -> {
      let remaining =
        list.filter(state.messages, fn(message) {
          case message.cached, message.expires {
            False, _ -> False
            True, option.Some(expires) -> expires > now
            True, option.None -> True
          }
        })
      process.send(
        reply,
        Ok(list.length(state.messages) - list.length(remaining)),
      )
      actor.continue(State(..state, messages: remaining))
    }
    Stats(reply) -> {
      process.send(
        reply,
        Ok(storage.Stats(
          messages: list.length(state.messages),
          scheduled: state.messages
            |> list.filter(fn(message) { message.scheduled })
            |> list.length,
          events: state.events,
        )),
      )
      actor.continue(state)
    }
    Migrate(reply) | Health(reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(state)
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
