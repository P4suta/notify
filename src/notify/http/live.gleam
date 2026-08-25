import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http.{Get}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/string
import gleam/string_tree
import mist
import notify/broker.{type Broker, type Delivery}
import notify/core/acl
import notify/core/filter
import notify/core/message
import notify/core/message_json
import notify/core/topic.{type Topic}
import notify/http/auth as http_auth
import notify/http/filter_params
import notify/http/parameter as http_parameter
import notify/runtime.{type Runtime}
import notify/since
import notify/storage

const keepalive_milliseconds = 45_000

type Format {
  JsonFormat
  RawFormat
}

type LiveRoute {
  JsonSubscription(String)
  RawSubscription(String)
  SseSubscription(String)
  WebSocketSubscription(String)
}

type State {
  State(
    subscription: Int,
    subject: Subject(Delivery),
    topics: List(Topic),
    bus: Broker,
    runtime: Runtime,
  )
}

type Prepared {
  Prepared(
    subscription: Int,
    topics: List(Topic),
    replay: List(message.Message),
  )
}

pub fn route(
  request: Request(mist.Connection),
  runtime: Runtime,
  bus: Broker,
  buffer_capacity: Int,
) -> Option(Response(mist.ResponseData)) {
  case match_route(request) {
    Some(JsonSubscription(topics)) ->
      Some(chunked(request, topics, JsonFormat, runtime, bus, buffer_capacity))
    Some(RawSubscription(topics)) ->
      Some(chunked(request, topics, RawFormat, runtime, bus, buffer_capacity))
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
  format: Format,
  runtime: Runtime,
  bus: Broker,
  capacity: Int,
) -> Response(mist.ResponseData) {
  case topic.parse_many(topic_names) {
    Error(_) -> invalid_topic()
    Ok(topics) -> {
      case authorize(request, topics, runtime) {
        Error(failure) -> access_failure(failure)
        Ok(_) -> {
          case validate_since(request, runtime) {
            Error(_) -> invalid_since()
            Ok(marker) ->
              with_criteria(request, fn(criteria) {
                case
                  prepare_stream(
                    request,
                    runtime,
                    bus,
                    topics,
                    criteria,
                    marker,
                    capacity,
                  )
                {
                  Error(_) -> storage_unavailable()
                  Ok(prepared) -> {
                    let content_type = case format {
                      JsonFormat -> "application/x-ndjson; charset=utf-8"
                      RawFormat -> "text/plain; charset=utf-8"
                    }
                    let reply =
                      mist.chunked(
                        request:,
                        response: response.new(200)
                          |> response.set_header("content-type", content_type)
                          |> response.set_header("cache-control", "no-store"),
                        init: fn(subject) {
                          initialise(subject, prepared, runtime, bus)
                        },
                        loop: fn(state, delivery, connection) {
                          case delivery {
                            broker.Overflow -> {
                              let _ =
                                mist.send_chunk(
                                  connection,
                                  bit_array.from_string(overflow_payload(format)),
                                )
                              state.bus.unsubscribe(state.subscription)
                              mist.chunk_stop()
                            }
                            _ ->
                              case
                                mist.send_chunk(
                                  connection,
                                  bit_array.from_string(chunk_payload(
                                    delivery,
                                    format,
                                  )),
                                )
                              {
                                Error(_) -> {
                                  state.bus.unsubscribe(state.subscription)
                                  mist.chunk_stop()
                                }
                                Ok(_) -> {
                                  after_delivery(state, delivery)
                                  mist.chunk_continue(state)
                                }
                              }
                          }
                        },
                      )
                    cleanup_failed_stream(reply, bus, prepared.subscription)
                  }
                }
              })
          }
        }
      }
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
  case topic.parse_many(topic_names) {
    Error(_) -> invalid_topic()
    Ok(topics) ->
      case authorize(request, topics, runtime) {
        Error(failure) -> access_failure(failure)
        Ok(_) ->
          case validate_since(request, runtime) {
            Error(_) -> invalid_since()
            Ok(marker) ->
              with_criteria(request, fn(criteria) {
                case
                  prepare_stream(
                    request,
                    runtime,
                    bus,
                    topics,
                    criteria,
                    marker,
                    capacity,
                  )
                {
                  Error(_) -> storage_unavailable()
                  Ok(prepared) -> {
                    let reply =
                      mist.server_sent_events(
                        request:,
                        initial_response: response.new(200)
                          |> response.set_header(
                            "x-content-type-options",
                            "nosniff",
                          ),
                        init: fn(subject) {
                          initialise(subject, prepared, runtime, bus)
                        },
                        loop: fn(state, delivery, connection) {
                          let event = sse_event(delivery)
                          case mist.send_event(connection, event) {
                            Error(_) -> {
                              state.bus.unsubscribe(state.subscription)
                              actor.stop()
                            }
                            Ok(_) -> {
                              after_delivery(state, delivery)
                              case delivery {
                                broker.Overflow -> {
                                  state.bus.unsubscribe(state.subscription)
                                  actor.stop()
                                }
                                _ -> actor.continue(state)
                              }
                            }
                          }
                        },
                      )
                    cleanup_failed_stream(reply, bus, prepared.subscription)
                  }
                }
              })
          }
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
  case topic.parse_many(topic_names) {
    Error(_) -> invalid_topic()
    Ok(topics) ->
      case authorize(request, topics, runtime) {
        Error(failure) -> access_failure(failure)
        Ok(_) ->
          case validate_since(request, runtime) {
            Error(_) -> invalid_since()
            Ok(marker) ->
              with_criteria(request, fn(criteria) {
                case
                  prepare_stream(
                    request,
                    runtime,
                    bus,
                    topics,
                    criteria,
                    marker,
                    capacity,
                  )
                {
                  Error(_) -> storage_unavailable()
                  Ok(prepared) -> {
                    let reply =
                      mist.websocket(
                        request:,
                        on_init: fn(_) {
                          let subject = process.new_subject()
                          let state =
                            initialise(subject, prepared, runtime, bus)
                          let selector =
                            process.new_selector() |> process.select(subject)
                          #(state, Some(selector))
                        },
                        on_close: fn(state: State) {
                          state.bus.unsubscribe(state.subscription)
                        },
                        handler: fn(
                          state: State,
                          incoming: mist.WebsocketMessage(Delivery),
                          connection: mist.WebsocketConnection,
                        ) {
                          case incoming {
                            mist.Custom(delivery) ->
                              case
                                mist.send_text_frame(
                                  connection,
                                  websocket_payload(delivery),
                                )
                              {
                                Error(_) -> {
                                  state.bus.unsubscribe(state.subscription)
                                  mist.stop()
                                }
                                Ok(_) -> {
                                  after_delivery(state, delivery)
                                  case delivery {
                                    broker.Overflow -> {
                                      state.bus.unsubscribe(state.subscription)
                                      mist.stop()
                                    }
                                    _ -> mist.continue(state)
                                  }
                                }
                              }
                            mist.Text(_) | mist.Binary(_) ->
                              mist.continue(state)
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
              })
          }
      }
  }
}

fn initialise(
  subject: Subject(Delivery),
  prepared: Prepared,
  runtime: Runtime,
  bus: Broker,
) -> State {
  let Prepared(subscription:, topics:, replay:) = prepared
  let state = State(subscription:, subject:, topics:, bus:, runtime:)
  bus.activate_prepared(
    subscription,
    subject,
    open_delivery(runtime, topics),
    replay,
  )
  schedule_keepalive(state)
  state
}

fn prepare_stream(
  request: Request(body),
  runtime: Runtime,
  bus: Broker,
  topics: List(Topic),
  criteria: filter.Criteria,
  marker: storage.Since,
  capacity: Int,
) -> Result(Prepared, storage.Error) {
  let placeholder = process.new_subject()
  let subscription =
    bus.subscribe_paused_filtered(topics, criteria, placeholder, capacity)
  let replay =
    replay_messages(
      runtime,
      topics,
      criteria,
      marker,
      parameter(request, ["x-scheduled", "scheduled", "sched"])
        |> option.map(truthy)
        |> option.unwrap(False),
    )
  case replay {
    Error(error) -> {
      bus.unsubscribe(subscription)
      Error(error)
    }
    Ok(replay) -> Ok(Prepared(subscription:, topics:, replay:))
  }
}

pub fn replay_messages(
  runtime: Runtime,
  topics: List(Topic),
  criteria: filter.Criteria,
  marker: storage.Since,
  include_scheduled: Bool,
) -> Result(List(message.Message), storage.Error) {
  runtime.storage.query(storage.Query(
    topics:,
    since: marker,
    include_scheduled:,
    criteria:,
  ))
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

fn validate_since(
  request: Request(body),
  runtime: Runtime,
) -> Result(storage.Since, since.Error) {
  let runtime.Clock(now) = runtime.clock
  since.parse(
    parameter(request, ["x-since", "since", "si"]),
    poll: False,
    now: now(),
  )
}

fn open_delivery(runtime: Runtime, topics: List(Topic)) -> Delivery {
  let runtime.Clock(now) = runtime.clock
  let runtime.IdGenerator(next_id) = runtime.ids
  broker.Open(next_id(), now(), topics)
}

fn keepalive_delivery(runtime: Runtime, topics: List(Topic)) -> Delivery {
  let runtime.Clock(now) = runtime.clock
  let runtime.IdGenerator(next_id) = runtime.ids
  broker.Keepalive(next_id(), now(), topics)
}

fn schedule_keepalive(state: State) -> Nil {
  let _ =
    process.send_after(
      state.subject,
      keepalive_milliseconds,
      keepalive_delivery(state.runtime, state.topics),
    )
  Nil
}

fn after_delivery(state: State, delivery: Delivery) -> Nil {
  case delivery {
    broker.Message(_) | broker.Replay(_) -> state.bus.ack(state.subscription)
    broker.Keepalive(..) -> schedule_keepalive(state)
    broker.Open(..) | broker.Overflow -> Nil
  }
}

fn chunk_payload(delivery: Delivery, format: Format) -> String {
  case format, delivery {
    RawFormat, broker.Message(message) | RawFormat, broker.Replay(message) ->
      message.message
      |> string.replace("\n", " ")
      |> string.replace("\r", " ")
      |> fn(value) { value <> "\n" }
    RawFormat, _ -> "\n"
    JsonFormat, _ -> delivery_json(delivery) <> "\n"
  }
}

fn overflow_payload(format: Format) -> String {
  case format {
    RawFormat -> "\n"
    JsonFormat -> overflow_json() <> "\n"
  }
}

fn websocket_payload(delivery: Delivery) -> String {
  case delivery {
    broker.Overflow -> overflow_json()
    _ -> delivery_json(delivery)
  }
}

fn delivery_json(delivery: Delivery) -> String {
  case delivery {
    broker.Open(id, time, topics) ->
      message_json.encode_control(id:, time:, event: message.OpenEvent, topics:)
      |> json.to_string
    broker.Keepalive(id, time, topics) ->
      message_json.encode_control(
        id:,
        time:,
        event: message.KeepaliveEvent,
        topics:,
      )
      |> json.to_string
    broker.Message(message) | broker.Replay(message) ->
      message_json.encode(message) |> json.to_string
    broker.Overflow -> overflow_json()
  }
}

fn sse_event(delivery: Delivery) -> mist.SSEEvent {
  let event = case delivery {
    broker.Overflow -> mist.event(string_tree.from_string(overflow_json()))
    _ -> mist.event(string_tree.from_string(delivery_json(delivery)))
  }
  case delivery {
    broker.Open(..) -> mist.event_name(event, "open")
    broker.Keepalive(..) -> mist.event_name(event, "keepalive")
    broker.Overflow -> mist.event_name(event, "error")
    broker.Message(_) | broker.Replay(_) -> event
  }
}

fn overflow_json() -> String {
  "{\"code\":42909,\"http\":429,\"error\":\"slow subscriber buffer exhausted\"}"
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

fn with_criteria(
  request: Request(body),
  next: fn(filter.Criteria) -> Response(mist.ResponseData),
) -> Response(mist.ResponseData) {
  case filter_params.parse(request) {
    Ok(criteria) -> next(criteria)
    Error(_) -> invalid_priority()
  }
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

fn authorize(
  request: Request(mist.Connection),
  topics: List(Topic),
  runtime: Runtime,
) -> Result(acl.Principal, http_auth.Failure) {
  let runtime.Clock(now) = runtime.clock
  http_auth.check(request, runtime.access, topics, acl.Read, now())
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
