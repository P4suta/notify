import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import notify/audit.{type Event, type NewEvent, type Page, type Store}

type State {
  State(next_sequence: Int, events: List(Event))
}

type Command {
  Append(NewEvent, Subject(Result(Event, audit.Error)))
  Page(audit.Cursor, Bool, Int, Subject(Result(Page, audit.Error)))
  Health(Subject(Result(Nil, audit.Error)))
}

pub fn start() -> Result(Store, actor.StartError) {
  use started <- result.try(
    actor.new(State(next_sequence: 1, events: []))
    |> actor.on_message(handle)
    |> actor.start,
  )
  let subject = started.data
  Ok(
    audit.Store(
      append: fn(event) {
        process.call(subject, 5000, fn(reply) { Append(event, reply) })
      },
      page: fn(after, limit) {
        let #(cursor, has_cursor) = case after {
          None -> #(audit.Cursor(0), False)
          Some(cursor) -> #(cursor, True)
        }
        process.call(subject, 5000, fn(reply) {
          Page(cursor, has_cursor, limit, reply)
        })
      },
      health: fn() { process.call(subject, 5000, Health) },
    ),
  )
}

fn handle(state: State, command: Command) -> actor.Next(State, Command) {
  case command {
    Append(new_event, reply) ->
      case audit.validate_event(new_event) {
        Error(error) -> {
          process.send(reply, Error(error))
          actor.continue(state)
        }
        Ok(_) -> {
          let event = audit.from_new(state.next_sequence, new_event)
          process.send(reply, Ok(event))
          actor.continue(
            State(next_sequence: state.next_sequence + 1, events: [
              event,
              ..state.events
            ]),
          )
        }
      }
    Page(cursor, has_cursor, limit, reply) -> {
      let after = case has_cursor {
        True -> Some(cursor)
        False -> None
      }
      case audit.validate_page(after, limit) {
        Error(error) -> process.send(reply, Error(error))
        Ok(_) -> {
          let selected = case after {
            None -> state.events
            Some(audit.Cursor(sequence)) ->
              list.filter(state.events, fn(event) { event.sequence < sequence })
          }
          process.send(
            reply,
            Ok(audit.page_from_rows(list.take(selected, limit + 1), limit)),
          )
        }
      }
      actor.continue(state)
    }
    Health(reply) -> {
      process.send(reply, Ok(Nil))
      actor.continue(state)
    }
  }
}
