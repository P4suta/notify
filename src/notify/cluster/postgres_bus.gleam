import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision.{type ChildSpecification}
import gleam/result
import gleam/string
import notify/core/message.{type Message}
import notify/storage
import notify/storage/postgres.{type Adapter}
import postgleam/config as postgres_config
import postgleam/connection
import postgleam/error as postgres_error
import postgleam/message as postgres_message
import postgleam/notifications

const batch_size = 256

const reconnect_milliseconds = 1000

const notification_wait_milliseconds = 1000

const wake_coalesce_milliseconds = 5

const flush_timeout_milliseconds = 5000

/// Starts the PostgreSQL cluster wake-up listener. LISTEN/NOTIFY only reduces
/// latency: the durable event log and per-node cursor remain the source of
/// truth, and every wake or quiet timeout drains the cursor so a lost
/// notification cannot strand committed events.
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
        Ok(listening) -> {
          let _ = drain_all(adapter, node_id, dispatch)
          listen_loop(listening, config, adapter, node_id, dispatch)
        }
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
  case connection.receive_message(state, notification_wait_milliseconds) {
    Ok(#(postgres_message.NotificationResponse(_, _, _), next_state)) -> {
      // Give concurrent commits a very small window to coalesce. Reissuing
      // the idempotent LISTEN command then drains queued NotificationResponse frames before one
      // authoritative event-log catch-up, rather than polling PostgreSQL in a
      // tight loop or issuing one cursor read for every wake-up.
      process.sleep(wake_coalesce_milliseconds)
      case flush_notifications(next_state) {
        Error(_) ->
          reconnect_listener(next_state, config, adapter, node_id, dispatch)
        Ok(flushed_state) -> {
          let _ = drain_all(adapter, node_id, dispatch)
          listen_loop(flushed_state, config, adapter, node_id, dispatch)
        }
      }
    }
    Ok(#(postgres_message.NoticeResponse(_), next_state)) ->
      listen_loop(next_state, config, adapter, node_id, dispatch)
    Ok(#(_, next_state)) ->
      reconnect_listener(next_state, config, adapter, node_id, dispatch)
    Error(error) ->
      case receive_timed_out(error) {
        True -> {
          // LISTEN/NOTIFY is only a wake-up hint. The timeout catch-up also
          // covers notifications lost while a listener was reconnecting.
          let _ = drain_all(adapter, node_id, dispatch)
          listen_loop(state, config, adapter, node_id, dispatch)
        }
        False -> reconnect_listener(state, config, adapter, node_id, dispatch)
      }
  }
}

fn flush_notifications(
  state: connection.ConnectionState,
) -> Result(connection.ConnectionState, postgres_error.Error) {
  notifications.listen(state, "notify_events", flush_timeout_milliseconds)
}

fn receive_timed_out(error: postgres_error.Error) -> Bool {
  case error {
    postgres_error.SocketError(detail) ->
      string.contains(detail, "timed out")
      || string.ends_with(detail, "timeout")
    _ -> False
  }
}

fn reconnect_listener(
  state: connection.ConnectionState,
  config: postgres_config.Config,
  adapter: Adapter,
  node_id: String,
  dispatch: fn(Message) -> Result(Nil, storage.Error),
) -> Nil {
  connection.disconnect(state)
  process.sleep(reconnect_milliseconds)
  connect_loop(config, adapter, node_id, dispatch)
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
