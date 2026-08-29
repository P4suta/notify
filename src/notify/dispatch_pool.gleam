import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/result

/// A bounded round-robin dispatcher. Workers own their state (for example a
/// database connection), while the dispatcher only forwards commands and can
/// never be held up by the operation itself.
pub opaque type Pool(message) {
  Pool(subject: Subject(message))
}

type State(message) {
  State(workers: List(Subject(message)), remaining: List(Subject(message)))
}

pub fn start(
  size: Int,
  worker: fn() -> Result(Subject(message), error),
  dispatcher_error: fn() -> error,
) -> Result(Pool(message), error) {
  use workers <- result.try(start_workers(max(1, size), worker, []))
  actor.new(State(workers:, remaining: workers))
  |> actor.on_message(dispatch)
  |> actor.start
  |> result.map(fn(started) { Pool(started.data) })
  |> result.map_error(fn(_) { dispatcher_error() })
}

pub fn send(pool: Pool(message), message: message) -> Nil {
  let Pool(subject) = pool
  process.send(subject, message)
}

fn start_workers(
  remaining: Int,
  worker: fn() -> Result(Subject(message), error),
  accumulated: List(Subject(message)),
) -> Result(List(Subject(message)), error) {
  case remaining {
    0 -> Ok(list.reverse(accumulated))
    _ -> {
      use subject <- result.try(worker())
      start_workers(remaining - 1, worker, [subject, ..accumulated])
    }
  }
}

fn dispatch(
  state: State(message),
  message: message,
) -> actor.Next(State(message), message) {
  let #(worker, remaining) = case state.remaining {
    [worker, ..remaining] -> #(worker, remaining)
    [] -> {
      let assert [worker, ..remaining] = state.workers
      #(worker, remaining)
    }
  }
  process.send(worker, message)
  actor.continue(State(..state, remaining:))
}

fn max(first: Int, second: Int) -> Int {
  case first > second {
    True -> first
    False -> second
  }
}
