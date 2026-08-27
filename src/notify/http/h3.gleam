//// HTTP/3 adapter for the transport-neutral Notify application surface.

import gleam/bit_array
import gleam/erlang/process.{type Selector, type Subject}
import gleam/http.{type Header, type Method, Get}
import gleam/http/request.{type Request, Request}
import gleam/http/response.{type Response, Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import http3/address as h3_address
import http3/server as h3_server
import http3/websocket
import notify/attachment_store
import notify/broker.{type Broker, type Delivery}
import notify/config.{type Config}
import notify/core/acl
import notify/core/message
import notify/core/message_json
import notify/core/topic.{type Topic}
import notify/http/attachment_upload
import notify/http/auth as http_auth
import notify/http/filter_params
import notify/http/live
import notify/http/parameter
import notify/http/rate_enforcer
import notify/http/router
import notify/http/transport
import notify/log as notify_log
import notify/runtime.{type Runtime}
import notify/since

const subscription_capacity = 128

const keepalive_milliseconds = 45_000

type Outcome {
  Outcome(status: Int, succeeded: Bool)
}

type SubscriptionFormat {
  JsonFormat
  RawFormat
  SseFormat
}

type Prepared {
  Prepared(
    subscription: Int,
    topics: List(Topic),
    replay: List(message.Message),
  )
}

type Active {
  Active(
    subscription: Int,
    subject: Subject(Delivery),
    topics: List(Topic),
    bus: Broker,
    application: Runtime,
  )
}

type WebSocketSignal {
  SocketEvent(websocket.Event)
  SocketFailed
}

type WebSocketLoopEvent {
  WebSocketDelivery(Delivery)
  WebSocketInput(WebSocketSignal)
}

type H3BodyState {
  H3BodyState(request: h3_server.Request, buffered: BitArray)
}

/// Serve one accepted request using only its QUIC-validated peer endpoint.
///
/// Forwarded headers are retained for application compatibility but are never
/// used to derive the HTTP/3 rate-limit or audit peer.
pub fn handle(
  incoming: h3_server.Request,
  application: Runtime,
  bus: Broker,
  configuration: Config,
) -> Bool {
  let started_at = monotonic_milliseconds()
  case verified_peer_ip(incoming) {
    Error(_) -> send_unidentified_failure(incoming)
    Ok(client_ip) ->
      case
        request_from_parts(
          h3_server.method(incoming),
          h3_server.scheme(incoming),
          h3_server.authority(incoming),
          h3_server.path(incoming),
          h3_server.headers(incoming),
          <<>>,
        )
      {
        Error(_) -> send_unidentified_failure(incoming)
        Ok(head) -> {
          let request_id = router.correlation_id(head)
          let head =
            head
            |> request.set_header("x-request-id", request_id)
            |> request.set_header("x-notify-client-ip", client_ip)
          let context =
            transport.Context(
              protocol: transport.Http3,
              scheme: h3_server.scheme(incoming),
              authority: h3_server.authority(incoming),
              request_id:,
              peer_ip: client_ip,
              forwarded_headers_trusted: False,
            )
          let outcome =
            route(incoming, head, context, application, bus, configuration)
          let runtime.Clock(now) = application.clock
          notify_log.request(
            log_format(configuration.log_format),
            at: now(),
            request_id: context.request_id,
            client_ip: context.peer_ip,
            method: http_method(head.method),
            target: h3_server.path(incoming),
            http_protocol: transport.protocol_string(context.protocol),
            status: outcome.status,
            duration_ms: int.max(0, monotonic_milliseconds() - started_at),
          )
          outcome.succeeded
        }
      }
  }
}

fn route(
  incoming: h3_server.Request,
  head: Request(BitArray),
  context: transport.Context,
  application: Runtime,
  bus: Broker,
  configuration: Config,
) -> Outcome {
  let application_request = case h3_server.protocol(incoming) {
    Some("websocket") -> request.set_method(head, Get)
    _ -> head
  }
  case
    rate_enforcer.preflight(
      application_request,
      application,
      context.peer_ip,
      configuration.max_request_bytes,
    )
  {
    Error(reply) -> send_bounded(incoming, with_request_id(reply, context))
    Ok(rate_headers) ->
      case h3_server.protocol(incoming) {
        Some("websocket") ->
          serve_websocket(
            incoming,
            application_request,
            context,
            application,
            bus,
            rate_headers,
          )
        Some(_) ->
          send_bounded(
            incoming,
            json_response(
              501,
              "{\"code\":50101,\"http\":501,\"error\":\"extended CONNECT protocol not supported\"}",
            )
              |> with_request_id(context)
              |> apply_headers(rate_headers),
          )
        None ->
          case subscription_route(application_request) {
            Some(#(topic_names, format)) ->
              serve_subscription(
                incoming,
                application_request,
                context,
                application,
                bus,
                topic_names,
                format,
                rate_headers,
              )
            None ->
              serve_bounded(
                incoming,
                application_request,
                context,
                application,
                configuration.max_request_bytes,
                rate_headers,
              )
          }
      }
  }
}

fn serve_bounded(
  incoming: h3_server.Request,
  head: Request(BitArray),
  context: transport.Context,
  application: Runtime,
  maximum_request_bytes: Int,
  rate_headers: List(Header),
) -> Outcome {
  case
    router.streamed_attachment(head, application, fn(store, expires) {
      attachment_upload.consume(
        h3_body_reader(incoming),
        store,
        expires,
        maximum_request_bytes,
      )
    })
  {
    Some(reply) ->
      finalize_bounded(
        incoming,
        head,
        reply,
        context,
        application,
        rate_headers,
      )
    None ->
      serve_download_or_buffered(
        incoming,
        head,
        context,
        application,
        rate_headers,
      )
  }
}

fn serve_download_or_buffered(
  incoming: h3_server.Request,
  head: Request(BitArray),
  context: transport.Context,
  application: Runtime,
  rate_headers: List(Header),
) -> Outcome {
  case router.streamed_download(head, application) {
    Some(router.AttachmentDownloadResponse(reply)) ->
      finalize_bounded(
        incoming,
        head,
        reply,
        context,
        application,
        rate_headers,
      )
    Some(router.AttachmentDownloadStream(status, headers, handle)) ->
      serve_attachment_download(
        incoming,
        head,
        status,
        headers,
        handle,
        context,
        application,
        rate_headers,
      )
    None -> {
      let reply = case h3_server.read_body(incoming) {
        Error(h3_server.RequestBodyTooLarge(limit)) ->
          json_response(
            413,
            "{\"code\":41301,\"http\":413,\"error\":\"request body too large\",\"limit\":"
              <> int.to_string(limit)
              <> "}",
          )
        Error(_) ->
          json_response(
            400,
            "{\"code\":40001,\"http\":400,\"error\":\"invalid request body\"}",
          )
        Ok(body) ->
          head
          |> request.set_body(body)
          |> router.handle(application)
      }
      finalize_bounded(
        incoming,
        head,
        reply,
        context,
        application,
        rate_headers,
      )
    }
  }
}

fn h3_body_reader(
  incoming: h3_server.Request,
) -> transport.BodyReader(H3BodyState) {
  transport.body_reader(H3BodyState(incoming, <<>>), h3_body_next, fn(_) { Nil })
}

fn h3_body_next(
  state: H3BodyState,
  maximum_bytes: Int,
) -> Result(#(transport.BodyEvent, H3BodyState), transport.BodyError) {
  case bit_array.byte_size(state.buffered) > 0 {
    True -> h3_buffered_chunk(state, maximum_bytes)
    False ->
      case h3_server.next_event(state.request) {
        Ok(h3_server.Data(<<>>)) -> h3_body_next(state, maximum_bytes)
        Ok(h3_server.Data(chunk)) ->
          h3_buffered_chunk(
            H3BodyState(..state, buffered: chunk),
            maximum_bytes,
          )
        Ok(h3_server.Trailers(_)) -> h3_body_next(state, maximum_bytes)
        Ok(h3_server.End) -> Ok(#(transport.BodyEnd, state))
        Error(h3_server.RequestBodyTooLarge(limit)) ->
          Error(transport.BodyTooLarge(limit))
        Error(_) -> Error(transport.BodyUnavailable)
      }
  }
}

fn h3_buffered_chunk(
  state: H3BodyState,
  maximum_bytes: Int,
) -> Result(#(transport.BodyEvent, H3BodyState), transport.BodyError) {
  let buffered_bytes = bit_array.byte_size(state.buffered)
  let take = int.min(buffered_bytes, maximum_bytes)
  case
    bit_array.slice(state.buffered, at: 0, take:),
    bit_array.slice(state.buffered, at: take, take: buffered_bytes - take)
  {
    Ok(chunk), Ok(rest) ->
      Ok(#(transport.BodyChunk(chunk), H3BodyState(..state, buffered: rest)))
    _, _ -> Error(transport.BodyUnavailable)
  }
}

fn finalize_bounded(
  incoming: h3_server.Request,
  request: Request(BitArray),
  reply: Response(BitArray),
  context: transport.Context,
  application: Runtime,
  rate_headers: List(Header),
) -> Outcome {
  let reply =
    reply
    |> apply_headers(rate_headers)
    |> with_request_id(context)
    |> fn(reply) {
      rate_enforcer.after_response(request, reply, application, context.peer_ip)
    }
  send_bounded(incoming, reply)
}

fn serve_attachment_download(
  incoming: h3_server.Request,
  request: Request(BitArray),
  status: Int,
  headers: List(Header),
  handle: attachment_store.DownloadHandle,
  context: transport.Context,
  application: Runtime,
  rate_headers: List(Header),
) -> Outcome {
  let checked =
    response.new(status)
    |> response.set_body(<<>>)
    |> fn(reply) { Response(..reply, headers:) }
    |> apply_headers(rate_headers)
    |> with_request_id(context)
    |> fn(reply) {
      rate_enforcer.after_response(request, reply, application, context.peer_ip)
    }
  case checked.status == status {
    False -> {
      attachment_store.close(handle)
      send_bounded(incoming, checked)
    }
    True ->
      case
        h3_server.send_response(incoming, status, safe_headers(checked.headers))
      {
        Error(_) -> {
          attachment_store.close(handle)
          Outcome(status, False)
        }
        Ok(Nil) -> {
          let succeeded = attachment_download_loop(incoming, handle)
          attachment_store.close(handle)
          Outcome(status, succeeded)
        }
      }
  }
}

fn attachment_download_loop(
  incoming: h3_server.Request,
  handle: attachment_store.DownloadHandle,
) -> Bool {
  case
    attachment_store.read(handle, attachment_store.maximum_download_chunk_bytes)
  {
    Error(_) -> False
    Ok(attachment_store.DownloadEnd) ->
      h3_server.finish_response(incoming) |> result.is_ok
    Ok(attachment_store.DownloadChunk(chunk)) ->
      case h3_server.send_chunk(incoming, chunk) {
        Error(_) -> False
        Ok(Nil) -> attachment_download_loop(incoming, handle)
      }
  }
}

fn serve_subscription(
  incoming: h3_server.Request,
  request: Request(BitArray),
  context: transport.Context,
  application: Runtime,
  bus: Broker,
  topic_names: String,
  format: SubscriptionFormat,
  rate_headers: List(Header),
) -> Outcome {
  case
    prepare_subscription(
      request,
      application,
      bus,
      topic_names,
      subscription_capacity,
    )
  {
    Error(reply) -> {
      let reply =
        reply
        |> apply_headers(rate_headers)
        |> with_request_id(context)
        |> fn(reply) {
          rate_enforcer.after_response(
            request,
            reply,
            application,
            context.peer_ip,
          )
        }
      send_bounded(incoming, reply)
    }
    Ok(prepared) -> {
      let headers = [
        #("content-type", content_type(format)),
        #("cache-control", "no-store"),
        #("x-request-id", context.request_id),
        ..rate_headers
      ]
      let headers = case format {
        SseFormat -> [
          #("x-content-type-options", "nosniff"),
          #("x-accel-buffering", "no"),
          ..headers
        ]
        _ -> headers
      }
      case h3_server.send_response(incoming, 200, safe_headers(headers)) {
        Error(_) -> {
          unsubscribe_prepared(prepared, bus)
          Outcome(200, False)
        }
        Ok(Nil) -> {
          let active = activate(prepared, application, bus)
          let succeeded = subscription_loop(incoming, active, format)
          Outcome(200, succeeded)
        }
      }
    }
  }
}

fn subscription_loop(
  incoming: h3_server.Request,
  active: Active,
  format: SubscriptionFormat,
) -> Bool {
  let delivery = process.receive_forever(active.subject)
  let payload = subscription_payload(delivery, format)
  case h3_server.send_chunk(incoming, <<payload:utf8>>) {
    Error(_) -> {
      active.bus.unsubscribe(active.subscription)
      False
    }
    Ok(Nil) -> {
      after_delivery(active, delivery)
      case delivery {
        broker.Overflow -> {
          active.bus.unsubscribe(active.subscription)
          h3_server.finish_response(incoming) |> result.is_ok
        }
        _ -> subscription_loop(incoming, active, format)
      }
    }
  }
}

fn serve_websocket(
  incoming: h3_server.Request,
  request: Request(BitArray),
  context: transport.Context,
  application: Runtime,
  bus: Broker,
  rate_headers: List(Header),
) -> Outcome {
  case request.path_segments(request) {
    [topic_names, "ws"] ->
      case
        prepare_subscription(
          request,
          application,
          bus,
          topic_names,
          subscription_capacity,
        )
      {
        Error(reply) -> {
          let reply =
            reply
            |> apply_headers(rate_headers)
            |> with_request_id(context)
            |> fn(reply) {
              rate_enforcer.after_response(
                request,
                reply,
                application,
                context.peer_ip,
              )
            }
          send_bounded(incoming, reply)
        }
        Ok(prepared) -> {
          let headers =
            safe_headers([
              #("cache-control", "no-store"),
              #("x-request-id", context.request_id),
              ..rate_headers
            ])
          case
            websocket.accept_with_headers(websocket.new(), incoming, headers)
          {
            Error(_) -> {
              unsubscribe_prepared(prepared, bus)
              send_bounded(
                incoming,
                json_response(
                  400,
                  "{\"code\":40016,\"http\":400,\"error\":\"invalid WebSocket handshake\"}",
                )
                  |> with_request_id(context),
              )
            }
            Ok(socket) -> {
              let active = activate(prepared, application, bus)
              let succeeded = websocket_subscription_loop(active, socket)
              Outcome(200, succeeded)
            }
          }
        }
      }
    _ ->
      send_bounded(
        incoming,
        json_response(
          404,
          "{\"code\":40401,\"http\":404,\"error\":\"page not found\"}",
        )
          |> apply_headers(rate_headers)
          |> with_request_id(context),
      )
  }
}

fn websocket_subscription_loop(
  active: Active,
  socket: websocket.Socket,
) -> Bool {
  let socket_subject = process.new_subject()
  let _reader =
    process.spawn(fn() { receive_websocket(socket, socket_subject) })
  let selector =
    process.new_selector()
    |> process.select_map(active.subject, WebSocketDelivery)
    |> process.select_map(socket_subject, WebSocketInput)
  websocket_select(active, socket, selector)
}

fn receive_websocket(
  socket: websocket.Socket,
  subject: Subject(WebSocketSignal),
) -> Nil {
  case websocket.receive(socket) {
    Error(_) -> process.send(subject, SocketFailed)
    Ok(#(next, event)) -> {
      process.send(subject, SocketEvent(event))
      case event {
        websocket.CloseReceived(..) -> Nil
        _ -> receive_websocket(next, subject)
      }
    }
  }
}

fn websocket_select(
  active: Active,
  socket: websocket.Socket,
  selector: Selector(WebSocketLoopEvent),
) -> Bool {
  case process.selector_receive_forever(selector) {
    WebSocketInput(SocketFailed) -> {
      active.bus.unsubscribe(active.subscription)
      False
    }
    WebSocketInput(SocketEvent(websocket.CloseReceived(..))) -> {
      active.bus.unsubscribe(active.subscription)
      True
    }
    WebSocketInput(SocketEvent(_)) -> websocket_select(active, socket, selector)
    WebSocketDelivery(delivery) ->
      case websocket.send_text(socket, websocket_payload(delivery)) {
        Error(_) -> {
          active.bus.unsubscribe(active.subscription)
          let _ = websocket.cancel(socket)
          False
        }
        Ok(next) -> {
          after_delivery(active, delivery)
          case delivery {
            broker.Overflow -> {
              active.bus.unsubscribe(active.subscription)
              let closed =
                websocket.close(
                  next,
                  Some(1008),
                  "slow subscriber buffer exhausted",
                )
              case closed {
                Ok(closed) -> {
                  let _ = websocket.cancel(closed)
                  True
                }
                Error(_) -> False
              }
            }
            _ -> websocket_select(active, next, selector)
          }
        }
      }
  }
}

fn prepare_subscription(
  request: Request(BitArray),
  application: Runtime,
  bus: Broker,
  topic_names: String,
  capacity: Int,
) -> Result(Prepared, Response(BitArray)) {
  use topics <- result.try(parse_topics(topic_names))
  let runtime.Clock(now) = application.clock
  use _ <- result.try(
    http_auth.check(request, application.access, topics, acl.Read, now())
    |> result.map_error(access_failure),
  )
  use marker <- result.try(
    since.parse(
      parameter.read(request, ["x-since", "since", "si"]),
      poll: False,
      now: now(),
    )
    |> result.map_error(fn(_) { invalid_since() }),
  )
  use criteria <- result.try(
    filter_params.parse(request)
    |> result.map_error(fn(_) { invalid_priority() }),
  )
  let placeholder = process.new_subject()
  let subscription =
    bus.subscribe_paused_filtered(topics, criteria, placeholder, capacity)
  let replay =
    live.replay_messages(
      application,
      topics,
      criteria,
      marker,
      parameter.read(request, ["x-scheduled", "scheduled", "sched"])
        |> option.map(truthy)
        |> option.unwrap(False),
    )
  case replay {
    Error(_) -> {
      bus.unsubscribe(subscription)
      Error(storage_unavailable())
    }
    Ok(replay) -> Ok(Prepared(subscription:, topics:, replay:))
  }
}

fn activate(prepared: Prepared, application: Runtime, bus: Broker) -> Active {
  let Prepared(subscription:, topics:, replay:) = prepared
  let subject = process.new_subject()
  let active = Active(subscription:, subject:, topics:, bus:, application:)
  bus.activate_prepared(
    subscription,
    subject,
    open_delivery(application, topics),
    replay,
  )
  schedule_keepalive(active)
  active
}

fn unsubscribe_prepared(prepared: Prepared, bus: Broker) -> Nil {
  let Prepared(subscription:, ..) = prepared
  bus.unsubscribe(subscription)
}

fn schedule_keepalive(active: Active) -> Nil {
  let _timer =
    process.send_after(
      active.subject,
      keepalive_milliseconds,
      keepalive_delivery(active.application, active.topics),
    )
  Nil
}

fn after_delivery(active: Active, delivery: Delivery) -> Nil {
  case delivery {
    broker.Message(_) | broker.Replay(_) -> active.bus.ack(active.subscription)
    broker.Keepalive(..) -> schedule_keepalive(active)
    broker.Open(..) | broker.Overflow -> Nil
  }
}

fn open_delivery(application: Runtime, topics: List(Topic)) -> Delivery {
  let runtime.Clock(now) = application.clock
  let runtime.IdGenerator(next_id) = application.ids
  broker.Open(next_id(), now(), topics)
}

fn keepalive_delivery(application: Runtime, topics: List(Topic)) -> Delivery {
  let runtime.Clock(now) = application.clock
  let runtime.IdGenerator(next_id) = application.ids
  broker.Keepalive(next_id(), now(), topics)
}

fn subscription_route(
  request: Request(BitArray),
) -> Option(#(String, SubscriptionFormat)) {
  case request.method, request.path_segments(request), poll_requested(request) {
    Get, [topics, "json"], False -> Some(#(topics, JsonFormat))
    Get, [topics, "raw"], False -> Some(#(topics, RawFormat))
    Get, [topics, "sse"], False -> Some(#(topics, SseFormat))
    _, _, _ -> None
  }
}

fn poll_requested(request: Request(body)) -> Bool {
  parameter.read(request, ["x-poll", "poll", "po"])
  |> option.map(truthy)
  |> option.unwrap(False)
}

fn truthy(value: String) -> Bool {
  list.contains(["1", "true", "yes", "on"], string.lowercase(value))
}

fn parse_topics(names: String) -> Result(List(Topic), Response(BitArray)) {
  case topic.parse_many(names) {
    Error(_) -> Error(invalid_topic())
    Ok(topics) ->
      case topic.any_disallowed(topics) {
        True -> Error(disallowed_topic())
        False -> Ok(topics)
      }
  }
}

fn access_failure(failure: http_auth.Failure) -> Response(BitArray) {
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
    json_response(
      status,
      "{\"code\":"
        <> int.to_string(code)
        <> ",\"http\":"
        <> int.to_string(status)
        <> ",\"error\":\""
        <> detail
        <> "\"}",
    )
    |> response.set_header("cache-control", "no-store")
  case status == 401 {
    True ->
      response.set_header(reply, "www-authenticate", "Basic realm=\"notify\"")
    False -> reply
  }
}

fn invalid_topic() -> Response(BitArray) {
  json_response(
    404,
    "{\"code\":40401,\"http\":404,\"error\":\"page not found\"}",
  )
}

fn disallowed_topic() -> Response(BitArray) {
  json_response(
    400,
    "{\"code\":40010,\"http\":400,\"error\":\"invalid request: topic name is not allowed\"}",
  )
}

fn invalid_since() -> Response(BitArray) {
  json_response(
    400,
    "{\"code\":40008,\"http\":400,\"error\":\"invalid since parameter\"}",
  )
}

fn invalid_priority() -> Response(BitArray) {
  json_response(
    400,
    "{\"code\":40007,\"http\":400,\"error\":\"invalid priority parameter\"}",
  )
}

fn storage_unavailable() -> Response(BitArray) {
  json_response(
    503,
    "{\"code\":50301,\"http\":503,\"error\":\"storage unavailable\"}",
  )
  |> response.set_header("cache-control", "no-store")
}

fn content_type(format: SubscriptionFormat) -> String {
  case format {
    JsonFormat -> "application/x-ndjson; charset=utf-8"
    RawFormat -> "text/plain; charset=utf-8"
    SseFormat -> "text/event-stream; charset=utf-8"
  }
}

fn subscription_payload(
  delivery: Delivery,
  format: SubscriptionFormat,
) -> String {
  case format, delivery {
    RawFormat, broker.Message(message) | RawFormat, broker.Replay(message) ->
      message.message
      |> string.replace("\n", " ")
      |> string.replace("\r", " ")
      |> fn(value) { value <> "\n" }
    RawFormat, _ -> "\n"
    JsonFormat, _ -> websocket_payload(delivery) <> "\n"
    SseFormat, _ -> sse_payload(delivery)
  }
}

fn websocket_payload(delivery: Delivery) -> String {
  case delivery {
    broker.Overflow -> overflow_json()
    _ -> delivery_json(delivery)
  }
}

fn sse_payload(delivery: Delivery) -> String {
  let event = case delivery {
    broker.Open(..) -> "event: open\n"
    broker.Keepalive(..) -> "event: keepalive\n"
    broker.Overflow -> "event: error\n"
    broker.Message(_) | broker.Replay(_) -> ""
  }
  event <> "data: " <> websocket_payload(delivery) <> "\n\n"
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

fn overflow_json() -> String {
  "{\"code\":42909,\"http\":429,\"error\":\"slow subscriber buffer exhausted\"}"
}

/// Convert validated HTTP/3 request components into the shared HTTP model.
pub fn request_from_parts(
  method: Method,
  scheme: String,
  authority: String,
  target: String,
  headers: List(Header),
  body: BitArray,
) -> Result(Request(BitArray), Nil) {
  use parsed <- result.try(request.to(scheme <> "://" <> authority <> target))
  Ok(
    Request(
      ..parsed,
      method:,
      headers: headers
        |> list.filter(fn(header) { !string.starts_with(header.0, ":") })
        |> list.map(fn(header) { #(string.lowercase(header.0), header.1) }),
      body:,
    ),
  )
}

fn verified_peer_ip(request: h3_server.Request) -> Result(String, Nil) {
  h3_server.peer_endpoint(request)
  |> result.map(fn(endpoint) {
    endpoint |> h3_address.endpoint_address |> h3_address.to_string
  })
  |> result.map_error(fn(_) { Nil })
}

fn send_unidentified_failure(incoming: h3_server.Request) -> Bool {
  let reply =
    json_response(
      503,
      "{\"code\":50301,\"http\":503,\"error\":\"verified peer unavailable\"}",
    )
  send_bounded(incoming, reply).succeeded
}

fn send_bounded(
  incoming: h3_server.Request,
  reply: Response(BitArray),
) -> Outcome {
  Outcome(
    status: reply.status,
    succeeded: h3_server.respond(
      incoming,
      reply.status,
      safe_headers(reply.headers),
      reply.body,
    )
      |> result.is_ok,
  )
}

fn safe_headers(headers: List(Header)) -> List(Header) {
  headers
  |> list.filter(fn(header) {
    !list.contains(
      [
        "connection",
        "proxy-connection",
        "keep-alive",
        "transfer-encoding",
        "upgrade",
        "http2-settings",
      ],
      string.lowercase(header.0),
    )
  })
  |> list.map(fn(header) { #(string.lowercase(header.0), header.1) })
}

fn with_request_id(
  reply: Response(BitArray),
  context: transport.Context,
) -> Response(BitArray) {
  response.set_header(reply, "x-request-id", context.request_id)
}

fn apply_headers(
  reply: Response(BitArray),
  headers: List(Header),
) -> Response(BitArray) {
  list.fold(headers, reply, fn(reply, header) {
    response.set_header(reply, header.0, header.1)
  })
}

fn json_response(status: Int, body: String) -> Response(BitArray) {
  response.new(status)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(<<body:utf8>>)
}

fn http_method(method: Method) -> String {
  http.method_to_string(method)
}

fn log_format(format: config.LogFormat) -> notify_log.Format {
  case format {
    config.HumanLogs -> notify_log.Human
    config.JsonLogs -> notify_log.Json
  }
}

@external(erlang, "notify_ffi", "monotonic_milliseconds")
fn monotonic_milliseconds() -> Int
