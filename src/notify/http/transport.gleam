//// Transport-neutral HTTP request and response streaming contracts.
////
//// Adapters retain ownership of their sockets. The application sees only a
//// verified request context, a pull-based body, and a bounded or pull-based
//// response plan.

import gleam/http/response.{type Response}
import gleam/result

/// Negotiated HTTP protocol used by logs, metrics, and audit context.
pub type Protocol {
  Http1
  Http2
  Http3
}

/// Transport facts established before forwarded-header policy is applied.
pub type Context {
  Context(
    protocol: Protocol,
    scheme: String,
    authority: String,
    request_id: String,
    peer_ip: String,
    forwarded_headers_trusted: Bool,
  )
}

/// One pull from a request body.
pub type BodyEvent {
  BodyChunk(BitArray)
  BodyEnd
}

/// A transport or caller cancellation while reading a request body.
pub type BodyError {
  BodyUnavailable
  BodyCancelled
  BodyTooLarge(Int)
}

/// A pull-based request body with explicit cleanup.
pub opaque type BodyReader(state) {
  BodyReader(
    state: state,
    next: fn(state, Int) -> Result(#(BodyEvent, state), BodyError),
    cancel: fn(state) -> Nil,
  )
}

/// One pull from a streaming response body.
pub type StreamEvent {
  StreamChunk(BitArray)
  StreamEnd
}

/// A streaming response failure or downstream cancellation.
pub type StreamError {
  StreamUnavailable
  StreamCancelled
  SlowConsumer
}

/// A pull-based response body with explicit cleanup.
pub opaque type BodyStream {
  BodyStream(
    next: fn() -> Result(StreamEvent, StreamError),
    cancel: fn() -> Nil,
  )
}

/// A response head shared by every streaming adapter.
pub type ResponseHead {
  ResponseHead(status: Int, headers: List(#(String, String)))
}

/// The response shape selected by transport-neutral application routing.
pub type ResponsePlan {
  Bounded(Response(BitArray))
  Streaming(ResponseHead, BodyStream)
  WebSocket
}

/// Construct a request body reader from adapter-owned callbacks.
pub fn body_reader(
  state: state,
  next: fn(state, Int) -> Result(#(BodyEvent, state), BodyError),
  cancel: fn(state) -> Nil,
) -> BodyReader(state) {
  BodyReader(state:, next:, cancel:)
}

/// Pull at most `maximum_bytes` from the request body.
pub fn read(
  reader: BodyReader(state),
  maximum_bytes: Int,
) -> Result(#(BodyEvent, BodyReader(state)), BodyError) {
  reader.next(reader.state, maximum_bytes)
  |> result.map(fn(pulled) {
    #(pulled.0, BodyReader(..reader, state: pulled.1))
  })
}

/// Cancel a request body and release adapter-owned resources.
pub fn cancel_body(reader: BodyReader(state)) -> Nil {
  reader.cancel(reader.state)
}

/// Construct a response stream from adapter-owned callbacks.
pub fn body_stream(
  next: fn() -> Result(StreamEvent, StreamError),
  cancel: fn() -> Nil,
) -> BodyStream {
  BodyStream(next:, cancel:)
}

/// Pull the next response event.
pub fn next(stream: BodyStream) -> Result(StreamEvent, StreamError) {
  stream.next()
}

/// Cancel a response stream and release broker/storage resources.
pub fn cancel_stream(stream: BodyStream) -> Nil {
  stream.cancel()
}

/// Stable protocol label for structured logs.
pub fn protocol_string(protocol: Protocol) -> String {
  case protocol {
    Http1 -> "http/1.1"
    Http2 -> "h2"
    Http3 -> "h3"
  }
}
