import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import notify/broker.{type Broker, type Delivery}
import notify/core/acl
import notify/core/filter
import notify/core/message
import notify/core/message_json
import notify/core/topic.{type Topic}
import notify/http/auth as http_auth
import notify/http/filter_params
import notify/http/parameter
import notify/runtime.{type Runtime}
import notify/since
import notify/storage

const keepalive_milliseconds = 45_000

const overflow_json = "{\"code\":42909,\"http\":429,\"error\":\"slow subscriber buffer exhausted\"}"

pub type Format {
  Json
  Raw
  Sse
  WebSocket
}

pub type PrepareError {
  InvalidTopic
  DisallowedTopic
  Authorization(http_auth.Failure)
  InvalidSince
  InvalidFilter
  StorageFailure(storage.Error)
}

pub type Prepared {
  Prepared(
    subscription: Int,
    topics: List(Topic),
    replay: List(message.Message),
  )
}

pub type Active {
  Active(
    subscription: Int,
    subject: Subject(Delivery),
    topics: List(Topic),
    bus: Broker,
    runtime: Runtime,
  )
}

/// Validate and register a paused subscription before querying replay. Live
/// messages arriving during the query are buffered by the broker and are
/// ordered after replay when `activate` is called.
pub fn prepare(
  request: Request(body),
  runtime: Runtime,
  bus: Broker,
  topic_names: String,
  format: Format,
  capacity: Int,
) -> Result(Prepared, PrepareError) {
  use topics <- result.try(parse_topics(topic_names))
  let runtime.Clock(now) = runtime.clock
  use _ <- result.try(
    http_auth.check(request, runtime.access, topics, acl.Read, now())
    |> result.map_error(Authorization),
  )
  use marker <- result.try(
    since.parse(
      parameter.read(request, ["x-since", "since", "si"]),
      poll: False,
      now: now(),
    )
    |> result.map_error(fn(_) { InvalidSince }),
  )
  use criteria <- result.try(
    filter_params.parse(request)
    |> result.map_error(fn(_) { InvalidFilter }),
  )
  let placeholder = process.new_subject()
  let subscription =
    bus.subscribe_paused_filtered_as(
      topics,
      criteria,
      representation(format),
      placeholder,
      capacity,
    )
  case
    replay_messages(
      runtime,
      topics,
      criteria,
      marker,
      parameter.read(request, ["x-scheduled", "scheduled", "sched"])
        |> option.map(truthy)
        |> option.unwrap(False),
    )
  {
    Error(error) -> {
      bus.unsubscribe(subscription)
      Error(StorageFailure(error))
    }
    Ok(replay) -> Ok(Prepared(subscription:, topics:, replay:))
  }
}

pub fn activate(prepared: Prepared, runtime: Runtime, bus: Broker) -> Active {
  activate_on(prepared, runtime, bus, process.new_subject())
}

pub fn activate_on(
  prepared: Prepared,
  runtime: Runtime,
  bus: Broker,
  subject: Subject(Delivery),
) -> Active {
  let Prepared(subscription:, topics:, replay:) = prepared
  let active = Active(subscription:, subject:, topics:, bus:, runtime:)
  bus.activate_prepared(
    subscription,
    subject,
    open_delivery(runtime, topics),
    replay,
  )
  schedule_keepalive(active)
  active
}

pub fn unsubscribe_prepared(prepared: Prepared, bus: Broker) -> Nil {
  bus.unsubscribe(prepared.subscription)
}

pub fn after_delivery(active: Active, delivery: Delivery) -> Nil {
  case delivery {
    broker.Message(_) | broker.Replay(_) -> active.bus.ack(active.subscription)
    broker.Keepalive(..) -> schedule_keepalive(active)
    broker.Open(..) | broker.Overflow -> Nil
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

/// Return the complete wire payload for a delivery format. Message JSON and
/// raw lines come directly from the immutable binary prepared by the broker;
/// only subscriber-specific control events are encoded here.
pub fn payload(delivery: Delivery, format: Format) -> BitArray {
  case format, delivery {
    Raw, broker.Message(prepared) | Raw, broker.Replay(prepared) ->
      prepared.payload
    Raw, _ -> <<"\n":utf8>>
    Json, _ -> bit_array.append(structured(delivery), <<"\n":utf8>>)
    WebSocket, _ -> structured(delivery)
    Sse, _ -> {
      let event = case event_name(delivery) {
        None -> <<>>
        Some(name) -> bit_array.from_string("event: " <> name <> "\n")
      }
      bit_array.concat([
        event,
        <<"data: ":utf8>>,
        structured(delivery),
        <<"\n\n":utf8>>,
      ])
    }
  }
}

/// UTF-8 JSON used by Mist's SSE and WebSocket APIs.
pub fn structured_text(delivery: Delivery) -> String {
  delivery
  |> structured
  |> bit_array.to_string
  |> result.unwrap(overflow_json)
}

pub fn event_name(delivery: Delivery) -> Option(String) {
  case delivery {
    broker.Open(..) -> Some("open")
    broker.Keepalive(..) -> Some("keepalive")
    broker.Overflow -> Some("error")
    broker.Message(_) | broker.Replay(_) -> None
  }
}

fn structured(delivery: Delivery) -> BitArray {
  case delivery {
    broker.Open(id, time, topics) ->
      message_json.encode_control(id:, time:, event: message.OpenEvent, topics:)
      |> json.to_string
      |> bit_array.from_string
    broker.Keepalive(id, time, topics) ->
      message_json.encode_control(
        id:,
        time:,
        event: message.KeepaliveEvent,
        topics:,
      )
      |> json.to_string
      |> bit_array.from_string
    broker.Message(prepared) | broker.Replay(prepared) -> prepared.payload
    broker.Overflow -> bit_array.from_string(overflow_json)
  }
}

fn representation(format: Format) -> broker.Representation {
  case format {
    Raw -> broker.Raw
    Json | Sse | WebSocket -> broker.Structured
  }
}

fn parse_topics(names: String) -> Result(List(Topic), PrepareError) {
  case topic.parse_many(names) {
    Error(_) -> Error(InvalidTopic)
    Ok(topics) ->
      case topic.any_disallowed(topics) {
        True -> Error(DisallowedTopic)
        False -> Ok(topics)
      }
  }
}

fn truthy(value: String) -> Bool {
  list.contains(["1", "true", "yes", "on"], string.lowercase(value))
}

fn schedule_keepalive(active: Active) -> Nil {
  let _ =
    process.send_after(
      active.subject,
      keepalive_milliseconds,
      keepalive_delivery(active.runtime, active.topics),
    )
  Nil
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
