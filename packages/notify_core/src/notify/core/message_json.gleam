import gleam/dict
import gleam/dynamic/decode
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import notify/core/message.{
  type Action, type Attachment, type Draft, type Message,
}
import notify/core/topic

pub type DecodeError {
  MalformedJson
  InvalidJson
  InvalidTopic(topic.Error)
  InvalidPriority(Int)
}

type RawPriority {
  RawPriorityInt(Int)
  RawPriorityString(String)
}

type RawPublish {
  RawPublish(
    topic: String,
    message: String,
    title: Option(String),
    tags: List(String),
    priority: RawPriority,
    markdown: Bool,
    icon: Option(String),
    click: Option(String),
    attach: Option(String),
    filename: Option(String),
    actions: List(Action),
    delay: Option(String),
    sequence_id: Option(String),
    poll_id: Option(String),
    cache: Bool,
  )
}

pub fn encode(message: Message) -> Json {
  json.object(encode_fields(message))
}

/// Storage payloads preserve delivery state that must not appear on the ntfy
/// wire. `decoder` accepts both storage and wire payloads.
pub fn encode_storage(message: Message) -> Json {
  [
    #("_notify_cached", json.bool(message.cached)),
    #("_notify_scheduled", json.bool(message.scheduled)),
    ..encode_fields_reversed(message)
  ]
  |> list.reverse
  |> json.object
}

fn encode_fields(message: Message) -> List(#(String, Json)) {
  message |> encode_fields_reversed |> list.reverse
}

// Fields are accumulated in reverse wire order so every optional addition is
// constant time. The single final reverse above deliberately preserves the
// established ntfy byte representation and its stable key order.
fn encode_fields_reversed(message: Message) -> List(#(String, Json)) {
  let fields = [
    #("time", json.int(message.time)),
    #("id", json.string(message.id)),
  ]
  let fields = case message.event {
    message.MessageEvent ->
      prepend_optional(fields, "expires", message.expires, json.int)
    _ -> fields
  }
  let fields = [
    #("topic", json.string(topic.to_string(message.topic))),
    #("event", json.string(message.event |> message.event_to_string)),
    ..fields
  ]
  let fields = case message.event {
    message.MessageEvent | message.PollRequestEvent -> [
      #("message", json.string(message.message)),
      ..fields
    ]
    _ -> fields
  }
  let fields = prepend_optional(fields, "title", message.title, json.string)
  let fields = case message.priority {
    message.Default -> fields
    priority -> [
      #("priority", json.int(message.priority_to_int(priority))),
      ..fields
    ]
  }
  let fields = case message.tags {
    [] -> fields
    tags -> [#("tags", json.array(tags, json.string)), ..fields]
  }
  let fields = case message.markdown {
    False -> fields
    True -> [#("content_type", json.string("text/markdown")), ..fields]
  }
  let fields = prepend_optional(fields, "icon", message.icon, json.string)
  let fields = prepend_optional(fields, "click", message.click, json.string)
  let fields = case message.actions {
    [] -> fields
    actions -> [#("actions", json.array(actions, encode_action)), ..fields]
  }
  let fields =
    prepend_optional(
      fields,
      "attachment",
      message.attachment,
      encode_attachment,
    )
  fields
  |> prepend_optional("sequence_id", message.sequence_id, json.string)
  |> prepend_optional("poll_id", message.poll_id, json.string)
}

pub fn encode_control(
  id id: String,
  time time: Int,
  event event: message.Event,
  topics topics: List(topic.Topic),
) -> Json {
  json.object([
    #("id", json.string(id)),
    #("time", json.int(time)),
    #("event", json.string(message.event_to_string(event))),
    #("topic", json.string(topics |> topic.many_to_strings |> string.join(","))),
  ])
}

fn prepend_optional(
  fields: List(#(String, Json)),
  name: String,
  value: Option(a),
  encoder: fn(a) -> Json,
) -> List(#(String, Json)) {
  case value {
    None -> fields
    Some(value) -> [#(name, encoder(value)), ..fields]
  }
}

fn encode_action(action: Action) -> Json {
  case action {
    message.ViewAction(label:, url:, clear:, id:) ->
      [
        #("clear", json.bool(clear)),
        #("url", json.string(url)),
        #("label", json.string(label)),
        #("action", json.string("view")),
      ]
      |> prepend_optional("id", id, json.string)
      |> list.reverse
      |> json.object
    message.HttpAction(label:, url:, method:, headers:, body:, clear:, id:) -> {
      let fields = [
        #("clear", json.bool(clear)),
        #(
          "headers",
          json.object(
            list.map(headers, fn(pair) { #(pair.0, json.string(pair.1)) }),
          ),
        ),
        #("method", json.string(method)),
        #("url", json.string(url)),
        #("label", json.string(label)),
        #("action", json.string("http")),
      ]
      fields
      |> prepend_optional("body", body, json.string)
      |> prepend_optional("id", id, json.string)
      |> list.reverse
      |> json.object
    }
    message.CopyAction(label:, value:, clear:, id:) ->
      [
        #("clear", json.bool(clear)),
        #("value", json.string(value)),
        #("label", json.string(label)),
        #("action", json.string("copy")),
      ]
      |> prepend_optional("id", id, json.string)
      |> list.reverse
      |> json.object
  }
}

fn encode_attachment(attachment: Attachment) -> Json {
  let message.Attachment(name:, url:, mime_type:, size:, expires:) = attachment
  [#("url", json.string(url)), #("name", json.string(name))]
  |> prepend_optional("type", mime_type, json.string)
  |> prepend_optional("size", size, json.int)
  |> prepend_optional("expires", expires, json.int)
  |> list.reverse
  |> json.object
}

pub fn decode_publish(body: String) -> Result(Draft, DecodeError) {
  case json.parse(body, decode.dynamic) {
    Error(_) -> Error(MalformedJson)
    Ok(dynamic) ->
      case decode.run(dynamic, raw_publish_decoder()) {
        Error(_) -> Error(InvalidJson)
        Ok(raw) -> raw_to_draft(raw)
      }
  }
}

pub fn decode_actions(body: String) -> Result(List(Action), Nil) {
  json.parse(body, decode.list(action_decoder()))
  |> result.map_error(fn(_) { Nil })
}

pub fn decoder() -> decode.Decoder(Message) {
  use id <- decode.field("id", decode.string)
  use time <- decode.field("time", decode.int)
  use expires <- decode.optional_field(
    "expires",
    None,
    decode.optional(decode.int),
  )
  use event <- decode.field("event", event_decoder())
  use parsed_topic <- decode.field("topic", topic_decoder())
  use body <- decode.optional_field("message", "", decode.string)
  use title <- decode.optional_field(
    "title",
    None,
    decode.optional(decode.string),
  )
  use priority <- decode.optional_field(
    "priority",
    message.Default,
    priority_decoder(),
  )
  use tags <- decode.optional_field("tags", [], decode.list(decode.string))
  use markdown_flag <- decode.optional_field("markdown", False, decode.bool)
  use content_type <- decode.optional_field(
    "content_type",
    None,
    decode.optional(decode.string),
  )
  use icon <- decode.optional_field(
    "icon",
    None,
    decode.optional(decode.string),
  )
  use click <- decode.optional_field(
    "click",
    None,
    decode.optional(decode.string),
  )
  use actions <- decode.optional_field(
    "actions",
    [],
    decode.list(action_decoder()),
  )
  use attachment <- decode.optional_field(
    "attachment",
    None,
    decode.optional(attachment_decoder()),
  )
  use scheduled <- decode.optional_field(
    "_notify_scheduled",
    False,
    decode.bool,
  )
  use cached <- decode.optional_field("_notify_cached", True, decode.bool)
  use sequence_id <- decode.optional_field(
    "sequence_id",
    None,
    decode.optional(decode.string),
  )
  use poll_id <- decode.optional_field(
    "poll_id",
    None,
    decode.optional(decode.string),
  )
  decode.success(message.Message(
    id:,
    time:,
    expires:,
    event:,
    topic: parsed_topic,
    message: body,
    title:,
    priority:,
    tags:,
    markdown: markdown_flag || content_type == Some("text/markdown"),
    icon:,
    click:,
    actions:,
    attachment:,
    scheduled:,
    cached:,
    sequence_id:,
    poll_id:,
  ))
}

fn topic_decoder() -> decode.Decoder(topic.Topic) {
  use value <- decode.then(decode.string)
  case topic.parse(value) {
    Ok(topic) -> decode.success(topic)
    Error(_) -> {
      let assert Ok(placeholder) = topic.parse("invalid")
      decode.failure(placeholder, expected: "ntfy topic")
    }
  }
}

fn priority_decoder() -> decode.Decoder(message.Priority) {
  use value <- decode.then(decode.int)
  case message.priority_from_int(value) {
    Ok(priority) -> decode.success(priority)
    Error(_) ->
      decode.failure(message.Default, expected: "priority 1 through 5")
  }
}

fn event_decoder() -> decode.Decoder(message.Event) {
  use value <- decode.then(decode.string)
  case value {
    "open" -> decode.success(message.OpenEvent)
    "keepalive" -> decode.success(message.KeepaliveEvent)
    "message" -> decode.success(message.MessageEvent)
    "message_delete" -> decode.success(message.MessageDeleteEvent)
    "message_clear" -> decode.success(message.MessageClearEvent)
    "poll_request" -> decode.success(message.PollRequestEvent)
    _ -> decode.failure(message.MessageEvent, expected: "ntfy event")
  }
}

fn action_decoder() -> decode.Decoder(Action) {
  use action_type <- decode.field("action", decode.string)
  use id <- decode.optional_field("id", None, decode.optional(decode.string))
  case action_type {
    "view" -> {
      use label <- decode.field("label", decode.string)
      use url <- decode.field("url", decode.string)
      use clear <- decode.optional_field("clear", False, decode.bool)
      decode.success(message.ViewAction(label:, url:, clear:, id:))
    }
    "http" -> {
      use label <- decode.field("label", decode.string)
      use url <- decode.field("url", decode.string)
      use method <- decode.optional_field("method", "POST", decode.string)
      use headers <- decode.optional_field(
        "headers",
        dict.new(),
        decode.dict(decode.string, decode.string),
      )
      use body <- decode.optional_field(
        "body",
        None,
        decode.optional(decode.string),
      )
      use clear <- decode.optional_field("clear", False, decode.bool)
      decode.success(message.HttpAction(
        label:,
        url:,
        method:,
        headers: dict.to_list(headers),
        body:,
        clear:,
        id:,
      ))
    }
    "copy" -> {
      use label <- decode.field("label", decode.string)
      use value <- decode.field("value", decode.string)
      use clear <- decode.optional_field("clear", False, decode.bool)
      decode.success(message.CopyAction(label:, value:, clear:, id:))
    }
    _ ->
      decode.failure(
        message.CopyAction(
          label: action_type,
          value: action_type,
          clear: string.is_empty(action_type),
          id:,
        ),
        expected: "view, http, or copy action",
      )
  }
}

fn attachment_decoder() -> decode.Decoder(Attachment) {
  use name <- decode.field("name", decode.string)
  use url <- decode.field("url", decode.string)
  use mime_type <- decode.optional_field(
    "type",
    None,
    decode.optional(decode.string),
  )
  use size <- decode.optional_field("size", None, decode.optional(decode.int))
  use expires <- decode.optional_field(
    "expires",
    None,
    decode.optional(decode.int),
  )
  decode.success(message.Attachment(name:, url:, mime_type:, size:, expires:))
}

fn raw_publish_decoder() -> decode.Decoder(RawPublish) {
  use topic <- decode.field("topic", decode.string)
  use body <- decode.optional_field("message", "triggered", decode.string)
  use title <- decode.optional_field(
    "title",
    None,
    decode.optional(decode.string),
  )
  use tags <- decode.optional_field("tags", [], decode.list(decode.string))
  use priority <- decode.optional_field(
    "priority",
    RawPriorityInt(3),
    decode.one_of(decode.int |> decode.map(RawPriorityInt), or: [
      decode.string |> decode.map(RawPriorityString),
    ]),
  )
  use markdown <- decode.optional_field("markdown", False, decode.bool)
  use icon <- decode.optional_field(
    "icon",
    None,
    decode.optional(decode.string),
  )
  use click <- decode.optional_field(
    "click",
    None,
    decode.optional(decode.string),
  )
  use attach <- decode.optional_field(
    "attach",
    None,
    decode.optional(decode.string),
  )
  use filename <- decode.optional_field(
    "filename",
    None,
    decode.optional(decode.string),
  )
  use actions <- decode.optional_field(
    "actions",
    [],
    decode.list(action_decoder()),
  )
  use delay <- decode.optional_field(
    "delay",
    None,
    decode.optional(decode.string),
  )
  use sequence_id <- decode.optional_field(
    "sequence_id",
    None,
    decode.optional(decode.string),
  )
  use poll_id <- decode.optional_field(
    "poll_id",
    None,
    decode.optional(decode.string),
  )
  use cache <- decode.optional_field("cache", True, decode.bool)
  decode.success(RawPublish(
    topic:,
    message: body,
    title:,
    tags:,
    priority:,
    markdown:,
    icon:,
    click:,
    attach:,
    filename:,
    actions:,
    delay:,
    sequence_id:,
    poll_id:,
    cache:,
  ))
}

fn raw_to_draft(raw: RawPublish) -> Result(Draft, DecodeError) {
  use parsed_topic <- result.try(
    raw.topic
    |> topic.parse
    |> result.map_error(InvalidTopic),
  )
  use priority <- result.try(parse_raw_priority(raw.priority))
  let attachment = case raw.attach {
    None -> None
    Some(url) ->
      Some(message.Attachment(
        name: option.unwrap(raw.filename, "attachment"),
        url:,
        mime_type: None,
        size: None,
        expires: None,
      ))
  }
  Ok(message.Draft(
    topic: parsed_topic,
    message: raw.message,
    title: raw.title,
    priority:,
    tags: raw.tags,
    markdown: raw.markdown,
    icon: raw.icon,
    click: raw.click,
    actions: raw.actions,
    attachment:,
    delay: raw.delay,
    sequence_id: raw.sequence_id,
    poll_id: raw.poll_id,
    cache: raw.cache,
  ))
}

fn parse_raw_priority(
  priority: RawPriority,
) -> Result(message.Priority, DecodeError) {
  let parsed = case priority {
    RawPriorityInt(value) -> message.priority_from_int(value)
    RawPriorityString(value) -> message.parse_priority(value)
  }
  parsed
  |> result.map_error(fn(error) {
    let assert message.InvalidPriority(value) = error
    InvalidPriority(value)
  })
}
