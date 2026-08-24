import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import notify/core/message.{type Message}
import notify/storage
import notify/storage/postgres.{type Adapter}
import postgleam/config.{type Config}
import postgleam/connection
import postgleam/notifications

const batch_size = 100

const reconnect_milliseconds = 1000

/// Starts the PostgreSQL cluster wake-up listener. LISTEN/NOTIFY only reduces
/// latency: the durable event log and per-node cursor remain the source of
/// truth, and every loop drains the cursor even if a notification was lost.
pub fn start(
  config: Config,
  adapter: Adapter,
  node_id: String,
  broadcast: fn(Message) -> Nil,
) -> Pid {
  process.spawn(fn() { connect_loop(config, adapter, node_id, broadcast) })
}

pub fn supervised(
  config: Config,
  adapter: Adapter,
  node_id: String,
  broadcast: fn(Message) -> Nil,
) -> ChildSpecification(Nil) {
  supervision.worker(fn() {
    let pid = start(config, adapter, node_id, broadcast)
    Ok(actor.Started(pid:, data: Nil))
  })
}

fn connect_loop(
  config: Config,
  adapter: Adapter,
  node_id: String,
  broadcast: fn(Message) -> Nil,
) -> Nil {
  case connection.connect(config) {
    Error(_) -> {
      process.sleep(reconnect_milliseconds)
      connect_loop(config, adapter, node_id, broadcast)
    }
    Ok(state) ->
      case notifications.listen(state, "notify_events", 5000) {
        Error(_) -> {
          connection.disconnect(state)
          process.sleep(reconnect_milliseconds)
          connect_loop(config, adapter, node_id, broadcast)
        }
        Ok(listening) ->
          listen_loop(listening, config, adapter, node_id, broadcast)
      }
  }
}

fn listen_loop(
  state: connection.ConnectionState,
  config: Config,
  adapter: Adapter,
  node_id: String,
  broadcast: fn(Message) -> Nil,
) -> Nil {
  let _ = drain_all(adapter, node_id, broadcast)
  process.sleep(reconnect_milliseconds)
  case notifications.receive_notifications(state, 5000) {
    Error(_) -> {
      connection.disconnect(state)
      connect_loop(config, adapter, node_id, broadcast)
    }
    Ok(#(_, next_state)) ->
      listen_loop(next_state, config, adapter, node_id, broadcast)
  }
}

fn drain_all(
  adapter: Adapter,
  node_id: String,
  broadcast: fn(Message) -> Nil,
) -> Result(Int, storage.Error) {
  use count <- result.try(drain_once(adapter, node_id, broadcast))
  case count == batch_size {
    True ->
      drain_all(adapter, node_id, broadcast)
      |> result.map(fn(rest) { count + rest })
    False -> Ok(count)
  }
}

pub fn drain_once(
  adapter: Adapter,
  node_id: String,
  broadcast: fn(Message) -> Nil,
) -> Result(Int, storage.Error) {
  let postgres.Adapter(fetch_events:, ack_events:, ..) = adapter
  use events <- result.try(fetch_events(node_id, batch_size))
  list.each(events, fn(event) {
    case event.origin_node != node_id && !event.message.scheduled {
      True -> broadcast(event.message)
      False -> Nil
    }
  })
  case list.last(events) {
    Error(_) -> Ok(0)
    Ok(last) ->
      ack_events(node_id, last.sequence)
      |> result.map(fn(_) { list.length(events) })
  }
}
