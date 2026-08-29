import gleam/erlang/process.{type Subject}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

pub type Dependencies {
  Dependencies(
    storage: fn() -> Bool,
    attachments: fn() -> Bool,
    deliveries: fn() -> Bool,
    webpush: fn() -> Bool,
    audit: fn() -> Bool,
    http3: fn() -> Bool,
  )
}

pub type Snapshot {
  Snapshot(
    storage: Bool,
    attachments: Bool,
    deliveries: Bool,
    webpush: Bool,
    audit: Bool,
    http3: Bool,
  )
}

pub type Error {
  StartFailed
}

pub opaque type Monitor {
  Monitor(subject: Subject(Command), dependencies: Dependencies)
}

type ProbeResult {
  Storage(Bool)
  Attachments(Bool)
  Deliveries(Bool)
  WebPush(Bool)
  Audit(Bool)
  Http3(Bool)
}

type Command {
  Get(Subject(Snapshot))
}

type State {
  State(
    dependencies: Dependencies,
    cached: Option(Snapshot),
    checked_at: Int,
    cache_milliseconds: Int,
  )
}

const probe_timeout_milliseconds = 1000

pub fn start(
  dependencies: Dependencies,
  cache_milliseconds: Int,
) -> Result(Monitor, Error) {
  actor.new(State(
    dependencies:,
    cached: None,
    checked_at: 0,
    cache_milliseconds: max(0, cache_milliseconds),
  ))
  |> actor.on_message(handle)
  |> actor.start
  |> result.map(fn(started) { Monitor(started.data, dependencies) })
  |> result.map_error(fn(_) { StartFailed })
}

/// Returns the shared recent snapshot. If the monitor is unavailable, probing
/// remains fail-closed and independent rather than taking readiness down with
/// the cache process itself.
pub fn get(monitor: Monitor) -> Snapshot {
  let Monitor(subject, dependencies) = monitor
  let reply = process.new_subject()
  process.send(subject, Get(reply))
  case process.receive(reply, probe_timeout_milliseconds + 500) {
    Ok(snapshot) -> snapshot
    Error(_) -> probe(dependencies)
  }
}

pub fn ready(snapshot: Snapshot) -> Bool {
  snapshot.storage
  && snapshot.attachments
  && snapshot.deliveries
  && snapshot.webpush
  && snapshot.audit
  && snapshot.http3
}

/// Probes all independent dependencies in parallel with a single shared
/// deadline. A blocked dependency is left false while completed probes are
/// retained in the same immutable snapshot.
pub fn probe(dependencies: Dependencies) -> Snapshot {
  let results = process.new_subject()
  process.spawn_unlinked(fn() {
    process.send(results, Storage(dependencies.storage()))
  })
  process.spawn_unlinked(fn() {
    process.send(results, Attachments(dependencies.attachments()))
  })
  process.spawn_unlinked(fn() {
    process.send(results, Deliveries(dependencies.deliveries()))
  })
  process.spawn_unlinked(fn() {
    process.send(results, WebPush(dependencies.webpush()))
  })
  process.spawn_unlinked(fn() {
    process.send(results, Audit(dependencies.audit()))
  })
  process.spawn_unlinked(fn() {
    process.send(results, Http3(dependencies.http3()))
  })
  collect(
    results,
    6,
    monotonic_milliseconds() + probe_timeout_milliseconds,
    Snapshot(False, False, False, False, False, False),
  )
}

fn handle(state: State, command: Command) -> actor.Next(State, Command) {
  let Get(reply) = command
  let now = monotonic_milliseconds()
  let #(snapshot, next) = case state.cached {
    Some(snapshot)
      if now - state.checked_at >= 0
      && now - state.checked_at < state.cache_milliseconds
    -> #(snapshot, state)
    _ -> {
      let snapshot = probe(state.dependencies)
      #(
        snapshot,
        State(
          ..state,
          cached: Some(snapshot),
          checked_at: monotonic_milliseconds(),
        ),
      )
    }
  }
  process.send(reply, snapshot)
  actor.continue(next)
}

fn collect(
  results: Subject(ProbeResult),
  remaining: Int,
  deadline: Int,
  snapshot: Snapshot,
) -> Snapshot {
  case remaining {
    0 -> snapshot
    _ ->
      case
        process.receive(results, max(0, deadline - monotonic_milliseconds()))
      {
        Error(_) -> snapshot
        Ok(outcome) ->
          collect(results, remaining - 1, deadline, apply(snapshot, outcome))
      }
  }
}

fn apply(snapshot: Snapshot, outcome: ProbeResult) -> Snapshot {
  case outcome {
    Storage(value) -> Snapshot(..snapshot, storage: value)
    Attachments(value) -> Snapshot(..snapshot, attachments: value)
    Deliveries(value) -> Snapshot(..snapshot, deliveries: value)
    WebPush(value) -> Snapshot(..snapshot, webpush: value)
    Audit(value) -> Snapshot(..snapshot, audit: value)
    Http3(value) -> Snapshot(..snapshot, http3: value)
  }
}

fn max(first: Int, second: Int) -> Int {
  case first > second {
    True -> first
    False -> second
  }
}

@external(erlang, "notify_ffi", "monotonic_milliseconds")
fn monotonic_milliseconds() -> Int
