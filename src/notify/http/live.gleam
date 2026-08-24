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
import gleam/result
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
import notify/runtime.{type Runtime}
import notify/since
import notify/storage

const keepalive_milliseconds = 45_000

type Format {
  JsonFormat
  RawFormat
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

pub fn route(
  request: Request(mist.Connection),
  runtime: Runtime,
  bus: Broker,
  buffer_capacity: Int,
) -> Option(Response(mist.ResponseData)) {
  case request.method, request.path_segments(request), poll_requested(request) {
    Get, [topics, "json"], False ->
      Some(chunked(request, topics, JsonFormat, runtime, bus, buffer_capacity))
    Get, [topics, "raw"], False ->
      Some(chunked(request, topics, RawFormat, runtime, bus, buffer_capacity))
    Get, [topics, "sse"], False ->
      Some(sse(request, topics, runtime, bus, buffer_capacity))
    Get, [topics, "ws"], False ->
      Some(websocket(request, topics, runtime, bus, buffer_capacity))
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
            Ok(_) ->
              with_criteria(request, fn(criteria) {
                let content_type = case format {
                  JsonFormat -> "application/x-ndjson; charset=utf-8"
                  RawFormat -> "text/plain; charset=utf-8"
                }
                mist.chunked(
                  request:,
                  response: response.new(200)
                    |> response.set_header("content-type", content_type)
                    |> response.set_header("cache-control", "no-store"),
                  init: fn(subject) {
                    initialise(
                      subject,
                      topics,
                      criteria,
                      request,
                      runtime,
                      bus,
                      capacity,
                    )
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
            Ok(_) ->
              with_criteria(request, fn(criteria) {
                mist.server_sent_events(
                  request:,
                  initial_response: response.new(200)
                    |> response.set_header("x-content-type-options", "nosniff"),
                  init: fn(subject) {
                    initialise(
                      subject,
                      topics,
                      criteria,
                      request,
                      runtime,
                      bus,
                      capacity,
                    )
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
            Ok(_) ->
              with_criteria(request, fn(criteria) {
                mist.websocket(
                  request:,
                  on_init: fn(_) {
                    let subject = process.new_subject()
                    let state =
                      initialise(
                        subject,
                        topics,
                        criteria,
                        request,
                        runtime,
                        bus,
                        capacity,
                      )
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
                      mist.Text(_) | mist.Binary(_) -> mist.continue(state)
                      mist.Closed | mist.Shutdown -> {
                        state.bus.unsubscribe(state.subscription)
                        mist.stop()
                      }
                    }
                  },
                )
              })
          }
      }
  }
}

fn initialise(
  subject: Subject(Delivery),
  topics: List(Topic),
  criteria: filter.Criteria,
  request: Request(mist.Connection),
  runtime: Runtime,
  bus: Broker,
  capacity: Int,
) -> State {
  let subscription =
    bus.subscribe_paused_filtered(topics, criteria, subject, capacity)
  let state = State(subscription:, subject:, topics:, bus:, runtime:)
  process.send(subject, open_delivery(runtime, topics))
  let replay = replay_messages(request, runtime, topics, criteria)
  replay
  |> list.take(capacity)
  |> list.each(fn(message) { process.send(subject, broker.Replay(message)) })
  case list.length(replay) > capacity {
    True -> process.send(subject, broker.Overflow)
    False ->
      bus.activate(
        subscription,
        list.map(replay, fn(message) { message.id }),
        list.length(replay),
      )
  }
  schedule_keepalive(state)
  state
}

fn replay_messages(
  request: Request(body),
  runtime: Runtime,
  topics: List(Topic),
  criteria: filter.Criteria,
) -> List(message.Message) {
  let runtime.Clock(now) = runtime.clock
  case
    since.parse(
      parameter(request, ["since", "x-since", "si"]),
      poll: False,
      now: now(),
    )
  {
    Error(_) -> []
    Ok(marker) -> {
      let query =
        storage.Query(
          topics:,
          since: marker,
          include_scheduled: parameter(request, [
            "scheduled",
            "x-scheduled",
            "sched",
          ])
            |> option.map(truthy)
            |> option.unwrap(False),
          criteria:,
        )
      runtime.storage.query(query) |> result.unwrap([])
    }
  }
}

fn validate_since(
  request: Request(body),
  runtime: Runtime,
) -> Result(storage.Since, since.Error) {
  let runtime.Clock(now) = runtime.clock
  since.parse(
    parameter(request, ["since", "x-since", "si"]),
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
  parameter(request, ["poll", "x-poll", "po"])
  |> option.map(truthy)
  |> option.unwrap(False)
}

fn truthy(value: String) -> Bool {
  list.contains(["1", "true", "yes", "on"], string.lowercase(value))
}

fn parameter(request: Request(body), aliases: List(String)) -> Option(String) {
  let query = request.get_query(request) |> result.unwrap([])
  case
    list.find_map(aliases, fn(alias) {
      list.find_map(query, fn(pair) {
        case string.lowercase(pair.0) == alias {
          True -> Ok(pair.1)
          False -> Error(Nil)
        }
      })
    })
  {
    Ok(value) -> Some(value)
    Error(_) ->
      aliases
      |> list.find_map(fn(alias) { request.get_header(request, alias) })
      |> option.from_result
  }
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
