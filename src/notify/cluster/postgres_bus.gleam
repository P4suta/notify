import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import notify/core/message.{type Message}
import notify/storage
import notify/storage/postgres.{type Adapter}
import postgleam/config as postgres_config
import postgleam/connection
import postgleam/notifications

const batch_size = 100

const reconnect_milliseconds = 1000

/// Starts the PostgreSQL cluster wake-up listener. LISTEN/NOTIFY only reduces
/// latency: the durable event log and per-node cursor remain the source of
/// truth, and every loop drains the cursor even if a notification was lost.
pub fn start(
  config: postgres_config.Config,
  adapter: Adapter,
  node_id: String,
  dispatch: fn(Message) -> Result(Nil, storage.Error),
) -> Pid {
  process.spawn(fn() { connect_loop(config, adapter, node_id, dispatch) })
}

pub fn supervised(
  config: postgres_config.Config,
  adapter: Adapter,
  node_id: String,
  dispatch: fn(Message) -> Result(Nil, storage.Error),
) -> ChildSpecification(Nil) {
  supervision.worker(fn() {
    let pid = start(config, adapter, node_id, dispatch)
    Ok(actor.Started(pid:, data: Nil))
  })
}

fn connect_loop(
  config: postgres_config.Config,
  adapter: Adapter,
  node_id: String,
  dispatch: fn(Message) -> Result(Nil, storage.Error),
) -> Nil {
  case connection.connect(listener_config(config, node_id)) {
    Error(_) -> {
      process.sleep(reconnect_milliseconds)
      connect_loop(config, adapter, node_id, dispatch)
    }
    Ok(state) ->
      case notifications.listen(state, "notify_events", 5000) {
        Error(_) -> {
          connection.disconnect(state)
          process.sleep(reconnect_milliseconds)
          connect_loop(config, adapter, node_id, dispatch)
        }
        Ok(listening) ->
          listen_loop(listening, config, adapter, node_id, dispatch)
      }
  }
}

fn listen_loop(
  state: connection.ConnectionState,
  config: postgres_config.Config,
  adapter: Adapter,
  node_id: String,
  dispatch: fn(Message) -> Result(Nil, storage.Error),
) -> Nil {
  let _ = drain_all(adapter, node_id, dispatch)
  case notifications.receive_notifications(state, reconnect_milliseconds) {
    Error(_) -> {
      connection.disconnect(state)
      connect_loop(config, adapter, node_id, dispatch)
    }
    Ok(#(_, next_state)) ->
      listen_loop(next_state, config, adapter, node_id, dispatch)
  }
}

fn listener_config(
  config: postgres_config.Config,
  node_id: String,
) -> postgres_config.Config {
  let postgres_config.Config(extra_parameters:, ..) = config
  case
    list.any(extra_parameters, fn(parameter) {
      parameter.0 == "application_name"
    })
  {
    True -> config
    False ->
      postgres_config.extra_parameters(config, [
        #("application_name", "notify-listener-" <> node_id),
        ..extra_parameters
      ])
  }
}

fn drain_all(
  adapter: Adapter,
  node_id: String,
  dispatch: fn(Message) -> Result(Nil, storage.Error),
) -> Result(Int, storage.Error) {
  use count <- result.try(drain_once(adapter, node_id, dispatch))
  case count == batch_size {
    True ->
      drain_all(adapter, node_id, dispatch)
      |> result.map(fn(rest) { count + rest })
    False -> Ok(count)
  }
}

pub fn drain_once(
  adapter: Adapter,
  node_id: String,
  dispatch: fn(Message) -> Result(Nil, storage.Error),
) -> Result(Int, storage.Error) {
  let postgres.Adapter(fetch_events:, ack_events:, ..) = adapter
  use events <- result.try(fetch_events(node_id, batch_size))
  use _ <- result.try(
    list.try_each(events, fn(event) {
      case !event.message.scheduled {
        True -> dispatch(event.message)
        False -> Ok(Nil)
      }
    }),
  )
  case list.last(events) {
    Error(_) -> Ok(0)
    Ok(last) ->
      ack_events(node_id, last.sequence)
      |> result.map(fn(_) { list.length(events) })
  }
}
