import gleam/bytes_tree
import gleam/erlang/process
import gleam/http.{Get}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import gleam/string_tree
import mist
import notify/broker.{type Broker, type Delivery}
import notify/core/filter
import notify/core/message
import notify/core/topic.{type Topic}
import notify/http/auth as http_auth
import notify/http/parameter as http_parameter
import notify/http/subscription
import notify/runtime.{type Runtime}
import notify/storage

type LiveRoute {
  JsonSubscription(String)
  RawSubscription(String)
  SseSubscription(String)
  WebSocketSubscription(String)
}

pub fn route(
  request: Request(mist.Connection),
  runtime: Runtime,
  bus: Broker,
  buffer_capacity: Int,
) -> Option(Response(mist.ResponseData)) {
  case match_route(request) {
    Some(JsonSubscription(topics)) ->
      Some(chunked(
        request,
        topics,
        subscription.Json,
        runtime,
        bus,
        buffer_capacity,
      ))
    Some(RawSubscription(topics)) ->
      Some(chunked(
        request,
        topics,
        subscription.Raw,
        runtime,
        bus,
        buffer_capacity,
      ))
    Some(SseSubscription(topics)) ->
      Some(sse(request, topics, runtime, bus, buffer_capacity))
    Some(WebSocketSubscription(topics)) ->
      Some(websocket(request, topics, runtime, bus, buffer_capacity))
    None -> None
  }
}

pub fn matches(request: Request(body)) -> Bool {
  case match_route(request) {
    Some(_) -> True
    None -> False
  }
}

fn match_route(request: Request(body)) -> Option(LiveRoute) {
  case request.method, request.path_segments(request), poll_requested(request) {
    Get, [topics, "json"], False -> Some(JsonSubscription(topics))
    Get, [topics, "raw"], False -> Some(RawSubscription(topics))
    Get, [topics, "sse"], False -> Some(SseSubscription(topics))
    Get, [topics, "ws"], False -> Some(WebSocketSubscription(topics))
    _, _, _ -> None
  }
}

fn chunked(
  request: Request(mist.Connection),
  topic_names: String,
  format: subscription.Format,
  runtime: Runtime,
  bus: Broker,
  capacity: Int,
) -> Response(mist.ResponseData) {
  case
    subscription.prepare(request, runtime, bus, topic_names, format, capacity)
  {
    Error(error) -> prepare_error(error)
    Ok(prepared) -> {
      let content_type = case format {
        subscription.Json -> "application/x-ndjson; charset=utf-8"
        subscription.Raw -> "text/plain; charset=utf-8"
        subscription.Sse -> "text/event-stream; charset=utf-8"
        subscription.WebSocket -> "application/octet-stream"
      }
      let reply =
        mist.chunked(
          request:,
          response: response.new(200)
            |> response.set_header("content-type", content_type)
            |> response.set_header("cache-control", "no-store"),
          init: fn(subject) {
            subscription.activate_on(prepared, runtime, bus, subject)
          },
          loop: fn(state, delivery, connection) {
            case
              mist.send_chunk(
                connection,
                subscription.payload(delivery, format),
              )
            {
              Error(_) -> {
                state.bus.unsubscribe(state.subscription)
                mist.chunk_stop()
              }
              Ok(_) ->
                case delivery {
                  broker.Overflow -> {
                    state.bus.unsubscribe(state.subscription)
                    mist.chunk_stop()
                  }
                  _ -> {
                    subscription.after_delivery(state, delivery)
                    mist.chunk_continue(state)
                  }
                }
            }
          },
        )
      cleanup_failed_stream(reply, bus, prepared.subscription)
    }
  }
}

fn sse(
  request: Request(mist.Connection),
  topic_names: String,
  runtime: Runtime,
  bus: Broker,
  capacity: Int,
) -> Response(mist.ResponseData) {
  case
    subscription.prepare(
      request,
      runtime,
      bus,
      topic_names,
      subscription.Sse,
      capacity,
    )
  {
    Error(error) -> prepare_error(error)
    Ok(prepared) -> {
      let reply =
        mist.server_sent_events(
          request:,
          initial_response: response.new(200)
            |> response.set_header("x-content-type-options", "nosniff"),
          init: fn(subject) {
            subscription.activate_on(prepared, runtime, bus, subject)
          },
          loop: fn(state, delivery, connection) {
            case mist.send_event(connection, sse_event(delivery)) {
              Error(_) -> {
                state.bus.unsubscribe(state.subscription)
                actor.stop()
              }
              Ok(_) ->
                case delivery {
                  broker.Overflow -> {
                    state.bus.unsubscribe(state.subscription)
                    actor.stop()
                  }
                  _ -> {
                    subscription.after_delivery(state, delivery)
                    actor.continue(state)
                  }
                }
            }
          },
        )
      cleanup_failed_stream(reply, bus, prepared.subscription)
    }
  }
}

fn websocket(
  request: Request(mist.Connection),
  topic_names: String,
  runtime: Runtime,
  bus: Broker,
  capacity: Int,
) -> Response(mist.ResponseData) {
  case request.get_header(request, "upgrade") {
    Ok(value) ->
      case string.lowercase(string.trim(value)) == "websocket" {
        True -> websocket_upgraded(request, topic_names, runtime, bus, capacity)
        False -> websocket_upgrade_missing()
      }
    Error(_) -> websocket_upgrade_missing()
  }
}

fn websocket_upgraded(
  request: Request(mist.Connection),
  topic_names: String,
  runtime: Runtime,
  bus: Broker,
  capacity: Int,
) -> Response(mist.ResponseData) {
  case
    subscription.prepare(
      request,
      runtime,
      bus,
      topic_names,
      subscription.WebSocket,
      capacity,
    )
  {
    Error(error) -> prepare_error(error)
    Ok(prepared) -> {
      let reply =
        mist.websocket(
          request:,
          on_init: fn(_) {
            let subject = process.new_subject()
            let state =
              subscription.activate_on(prepared, runtime, bus, subject)
            let selector = process.new_selector() |> process.select(subject)
            #(state, Some(selector))
          },
          on_close: fn(state: subscription.Active) {
            state.bus.unsubscribe(state.subscription)
          },
          handler: fn(
            state: subscription.Active,
            incoming: mist.WebsocketMessage(Delivery),
            connection: mist.WebsocketConnection,
          ) {
            case incoming {
              mist.Custom(delivery) ->
                case
                  mist.send_text_frame(
                    connection,
                    subscription.structured_text(delivery),
                  )
                {
                  Error(_) -> {
                    state.bus.unsubscribe(state.subscription)
                    mist.stop()
                  }
                  Ok(_) ->
                    case delivery {
                      broker.Overflow -> {
                        state.bus.unsubscribe(state.subscription)
                        mist.stop()
                      }
                      _ -> {
                        subscription.after_delivery(state, delivery)
                        mist.continue(state)
                      }
                    }
                }
              mist.Text(_) | mist.Binary(_) -> mist.continue(state)
              mist.Closed | mist.Shutdown -> {
                state.bus.unsubscribe(state.subscription)
                mist.stop()
              }
            }
          },
        )
      cleanup_failed_stream(reply, bus, prepared.subscription)
    }
  }
}

fn websocket_upgrade_missing() -> Response(mist.ResponseData) {
  response.new(400)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(
      "{\"code\":40016,\"http\":400,\"error\":\"invalid request: client not using the websocket protocol\",\"link\":\"https://ntfy.sh/docs/subscribe/api/#websockets\"}",
    )),
  )
}

pub fn replay_messages(
  runtime: Runtime,
  topics: List(Topic),
  criteria: filter.Criteria,
  marker: storage.Since,
  include_scheduled: Bool,
) -> Result(List(message.Message), storage.Error) {
  subscription.replay_messages(
    runtime,
    topics,
    criteria,
    marker,
    include_scheduled,
  )
}

fn cleanup_failed_stream(
  reply: Response(mist.ResponseData),
  bus: Broker,
  subscription: Int,
) -> Response(mist.ResponseData) {
  case reply.status == 200 {
    True -> reply
    False -> {
      bus.unsubscribe(subscription)
      reply
    }
  }
}

fn sse_event(delivery: Delivery) -> mist.SSEEvent {
  let event =
    mist.event(string_tree.from_string(subscription.structured_text(delivery)))
  case subscription.event_name(delivery) {
    None -> event
    Some(name) -> mist.event_name(event, name)
  }
}

fn poll_requested(request: Request(body)) -> Bool {
  parameter(request, ["x-poll", "poll", "po"])
  |> option.map(truthy)
  |> option.unwrap(False)
}

fn truthy(value: String) -> Bool {
  list.contains(["1", "true", "yes", "on"], string.lowercase(value))
}

fn parameter(request: Request(body), aliases: List(String)) -> Option(String) {
  http_parameter.read(request, aliases)
}

fn invalid_topic() -> Response(mist.ResponseData) {
  response.new(404)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(
      "{\"code\":40401,\"http\":404,\"error\":\"page not found\"}",
    )),
  )
}

fn disallowed_topic() -> Response(mist.ResponseData) {
  response.new(400)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(
      "{\"code\":40010,\"http\":400,\"error\":\"invalid request: topic name is not allowed\"}",
    )),
  )
}

fn invalid_since() -> Response(mist.ResponseData) {
  response.new(400)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(
      "{\"code\":40008,\"http\":400,\"error\":\"invalid since parameter\"}",
    )),
  )
}

fn invalid_priority() -> Response(mist.ResponseData) {
  response.new(400)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(
      "{\"code\":40007,\"http\":400,\"error\":\"invalid priority parameter\"}",
    )),
  )
}

fn storage_unavailable() -> Response(mist.ResponseData) {
  response.new(503)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_header("cache-control", "no-store")
  |> response.set_body(
    mist.Bytes(bytes_tree.from_string(
      "{\"code\":50301,\"http\":503,\"error\":\"storage unavailable\"}",
    )),
  )
}

fn access_failure(failure: http_auth.Failure) -> Response(mist.ResponseData) {
  let #(status, code, detail) = case failure {
    http_auth.MalformedCredentials | http_auth.Unauthenticated -> #(
      401,
      40_101,
      "unauthorized",
    )
    http_auth.Forbidden -> #(403, 40_303, "forbidden")
    http_auth.SetupRequired -> #(503, 50_301, "server setup is required")
    http_auth.Unavailable -> #(503, 50_301, "authorization unavailable")
  }
  let reply =
    response.new(status)
    |> response.set_header("content-type", "application/json; charset=utf-8")
    |> response.set_header("cache-control", "no-store")
    |> response.set_body(
      mist.Bytes(bytes_tree.from_string(
        "{\"code\":"
        <> int.to_string(code)
        <> ",\"http\":"
        <> int.to_string(status)
        <> ",\"error\":\""
        <> detail
        <> "\"}",
      )),
    )
  case status == 401 {
    True ->
      response.set_header(reply, "www-authenticate", "Basic realm=\"notify\"")
    False -> reply
  }
}

fn prepare_error(
  error: subscription.PrepareError,
) -> Response(mist.ResponseData) {
  case error {
    subscription.InvalidTopic -> invalid_topic()
    subscription.DisallowedTopic -> disallowed_topic()
    subscription.Authorization(failure) -> access_failure(failure)
    subscription.InvalidSince -> invalid_since()
    subscription.InvalidFilter -> invalid_priority()
    subscription.StorageFailure(_) -> storage_unavailable()
  }
}
