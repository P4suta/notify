import gleam/int
import gleam/list
import gleam/option.{type Option, None}
import gleam/string
import notify/core/topic.{type Topic}

pub type Priority {
  Min
  Low
  Default
  High
  Max
}

pub type Event {
  OpenEvent
  KeepaliveEvent
  MessageEvent
  MessageDeleteEvent
  MessageClearEvent
  PollRequestEvent
}

pub type Action {
  ViewAction(label: String, url: String, clear: Bool)
  HttpAction(
    label: String,
    url: String,
    method: String,
    headers: List(#(String, String)),
    body: Option(String),
    clear: Bool,
  )
  CopyAction(label: String, value: String, clear: Bool)
}

pub type Attachment {
  Attachment(
    name: String,
    url: String,
    mime_type: Option(String),
    size: Option(Int),
    expires: Option(Int),
  )
}

pub type Draft {
  Draft(
    topic: Topic,
    message: String,
    title: Option(String),
    priority: Priority,
    tags: List(String),
    markdown: Bool,
    icon: Option(String),
    click: Option(String),
    actions: List(Action),
    attachment: Option(Attachment),
    delay: Option(String),
    sequence_id: Option(String),
    cache: Bool,
  )
}

pub type Message {
  Message(
    id: String,
    time: Int,
    expires: Option(Int),
    event: Event,
    topic: Topic,
    message: String,
    title: Option(String),
    priority: Priority,
    tags: List(String),
    markdown: Bool,
    icon: Option(String),
    click: Option(String),
    actions: List(Action),
    attachment: Option(Attachment),
    scheduled: Bool,
    cached: Bool,
    sequence_id: Option(String),
  )
}

pub type ValidationError {
  EmptyMessage
  InvalidId
  InvalidSequenceId
  InvalidPriority(Int)
  InvalidExpiry
}

pub fn plaintext_draft(topic: Topic, body: String) -> Draft {
  Draft(
    topic:,
    message: body,
    title: None,
    priority: Default,
    tags: [],
    markdown: False,
    icon: None,
    click: None,
    actions: [],
    attachment: None,
    delay: None,
    sequence_id: None,
    cache: True,
  )
}

pub fn materialise(
  draft: Draft,
  id id: String,
  now now: Int,
  expires expires: Int,
) -> Result(Message, ValidationError) {
  case string.length(draft.message), valid_id(id), expires > now {
    0, _, _ -> Error(EmptyMessage)
    _, False, _ -> Error(InvalidId)
    _, _, False -> Error(InvalidExpiry)
    _, True, True ->
      Ok(Message(
        id:,
        time: now,
        expires: case draft.cache {
          True -> option.Some(expires)
          False -> None
        },
        event: MessageEvent,
        topic: draft.topic,
        message: draft.message,
        title: draft.title,
        priority: draft.priority,
        tags: draft.tags,
        markdown: draft.markdown,
        icon: draft.icon,
        click: draft.click,
        actions: draft.actions,
        attachment: draft.attachment,
        scheduled: False,
        cached: draft.cache,
        sequence_id: draft.sequence_id,
      ))
  }
}

/// Builds an append-only control event for an existing sequence. Control
/// events deliberately have no message body or public expiry field, matching
/// the ntfy wire representation for clear and delete events.
pub fn materialise_control(
  topic topic: Topic,
  event event: Event,
  sequence_id sequence_id: String,
  id id: String,
  now now: Int,
) -> Result(Message, ValidationError) {
  case valid_id(id), valid_sequence_id(sequence_id), event {
    False, _, _ -> Error(InvalidId)
    _, False, _ -> Error(InvalidSequenceId)
    True, True, MessageClearEvent | True, True, MessageDeleteEvent ->
      Ok(Message(
        id:,
        time: now,
        expires: None,
        event:,
        topic:,
        message: "",
        title: None,
        priority: Default,
        tags: [],
        markdown: False,
        icon: None,
        click: None,
        actions: [],
        attachment: None,
        scheduled: False,
        cached: True,
        sequence_id: option.Some(sequence_id),
      ))
    True, True, _ -> Error(InvalidSequenceId)
  }
}

pub fn valid_id(value: String) -> Bool {
  string.length(value) == 10
  && value
  |> string.to_graphemes
  |> list.all(fn(character) {
    string.contains(
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
      character,
    )
  })
}

fn valid_sequence_id(value: String) -> Bool {
  string.length(value) > 0 && string.length(value) <= 64
}

pub fn priority_from_int(value: Int) -> Result(Priority, ValidationError) {
  case value {
    1 -> Ok(Min)
    2 -> Ok(Low)
    3 -> Ok(Default)
    4 -> Ok(High)
    5 -> Ok(Max)
    _ -> Error(InvalidPriority(value))
  }
}

pub fn priority_to_int(priority: Priority) -> Int {
  case priority {
    Min -> 1
    Low -> 2
    Default -> 3
    High -> 4
    Max -> 5
  }
}

pub fn parse_priority(value: String) -> Result(Priority, ValidationError) {
  case string.lowercase(value) {
    "min" -> Ok(Min)
    "low" -> Ok(Low)
    "default" -> Ok(Default)
    "high" -> Ok(High)
    "max" | "urgent" -> Ok(Max)
    numeric ->
      case int.parse(numeric) {
        Ok(value) -> priority_from_int(value)
        Error(_) -> Error(InvalidPriority(0))
      }
  }
}

pub fn event_to_string(event: Event) -> String {
  case event {
    OpenEvent -> "open"
    KeepaliveEvent -> "keepalive"
    MessageEvent -> "message"
    MessageDeleteEvent -> "message_delete"
    MessageClearEvent -> "message_clear"
    PollRequestEvent -> "poll_request"
  }
}
