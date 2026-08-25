import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

pub type Action {
  SetupComplete
  SessionLogin
  SessionLogout
  UserCreate
  UserUpdate
  UserDelete
  PasswordChange
  TokenCreate
  TokenRevoke
  AclChange
  AclRevoke
  AnonymousAccessChange
  DeliveryRetry
  DeliveryPurge
  AttachmentDelete
}

pub type Outcome {
  Attempted
  Succeeded
  Failed
  Denied
}

pub type NewEvent {
  NewEvent(
    occurred_at: Int,
    actor: String,
    action: Action,
    target: Option(String),
    outcome: Outcome,
    status: Option(Int),
    client_ip: String,
    request_id: String,
  )
}

pub type Event {
  Event(
    sequence: Int,
    occurred_at: Int,
    actor: String,
    action: Action,
    target: Option(String),
    outcome: Outcome,
    status: Option(Int),
    client_ip: String,
    request_id: String,
  )
}

pub type Cursor {
  Cursor(sequence: Int)
}

pub type Page {
  Page(items: List(Event), next: Option(Cursor))
}

pub type Error {
  InvalidEvent(String)
  InvalidPage
  Unavailable(String)
  Corrupt(String)
}

pub type Store {
  Store(
    append: fn(NewEvent) -> Result(Event, Error),
    page: fn(Option(Cursor), Int) -> Result(Page, Error),
    health: fn() -> Result(Nil, Error),
  )
}

pub fn new_event(
  occurred_at occurred_at: Int,
  actor actor: String,
  action action: Action,
  target target: Option(String),
  outcome outcome: Outcome,
  status status: Option(Int),
  client_ip client_ip: String,
  request_id request_id: String,
) -> Result(NewEvent, Error) {
  let event =
    NewEvent(
      occurred_at:,
      actor:,
      action:,
      target:,
      outcome:,
      status:,
      client_ip:,
      request_id:,
    )
  use _ <- result.try(validate_event(event))
  Ok(event)
}

pub fn validate_event(event: NewEvent) -> Result(Nil, Error) {
  case event.occurred_at < 0 {
    True -> Error(InvalidEvent("occurred_at"))
    False ->
      case bounded_printable(event.actor, 1, 64) {
        False -> Error(InvalidEvent("actor"))
        True ->
          case valid_optional_target(event.target) {
            False -> Error(InvalidEvent("target"))
            True ->
              case valid_status(event.status) {
                False -> Error(InvalidEvent("status"))
                True ->
                  case bounded_printable(event.client_ip, 1, 64) {
                    False -> Error(InvalidEvent("client_ip"))
                    True ->
                      case bounded_printable(event.request_id, 1, 64) {
                        False -> Error(InvalidEvent("request_id"))
                        True -> Ok(Nil)
                      }
                  }
              }
          }
      }
  }
}

pub fn from_new(sequence: Int, event: NewEvent) -> Event {
  Event(
    sequence:,
    occurred_at: event.occurred_at,
    actor: event.actor,
    action: event.action,
    target: event.target,
    outcome: event.outcome,
    status: event.status,
    client_ip: event.client_ip,
    request_id: event.request_id,
  )
}

pub fn validate_page(cursor: Option(Cursor), limit: Int) -> Result(Nil, Error) {
  let cursor_valid = case cursor {
    None -> True
    Some(Cursor(sequence)) -> sequence > 0
  }
  case cursor_valid && limit >= 1 && limit <= 100 {
    True -> Ok(Nil)
    False -> Error(InvalidPage)
  }
}

/// Builds a keyset page from rows ordered by descending sequence. Adapters
/// fetch `limit + 1` rows so this function can report whether another page
/// exists without a separate count query.
pub fn page_from_rows(rows: List(Event), limit: Int) -> Page {
  let items = list.take(rows, limit)
  let next = case list.length(rows) > limit {
    False -> None
    True ->
      items
      |> list.last
      |> result.map(fn(event) { Cursor(event.sequence) })
      |> option_from_result
  }
  Page(items:, next:)
}

pub fn action_name(action: Action) -> String {
  case action {
    SetupComplete -> "setup.complete"
    SessionLogin -> "session.login"
    SessionLogout -> "session.logout"
    UserCreate -> "user.create"
    UserUpdate -> "user.update"
    UserDelete -> "user.delete"
    PasswordChange -> "user.password_change"
    TokenCreate -> "token.create"
    TokenRevoke -> "token.revoke"
    AclChange -> "acl.change"
    AclRevoke -> "acl.revoke"
    AnonymousAccessChange -> "anonymous_access.change"
    DeliveryRetry -> "delivery.retry"
    DeliveryPurge -> "delivery.purge"
    AttachmentDelete -> "attachment.delete"
  }
}

pub fn action_from_name(value: String) -> Result(Action, Nil) {
  case value {
    "setup.complete" -> Ok(SetupComplete)
    "session.login" -> Ok(SessionLogin)
    "session.logout" -> Ok(SessionLogout)
    "user.create" -> Ok(UserCreate)
    "user.update" -> Ok(UserUpdate)
    "user.delete" -> Ok(UserDelete)
    "user.password_change" -> Ok(PasswordChange)
    "token.create" -> Ok(TokenCreate)
    "token.revoke" -> Ok(TokenRevoke)
    "acl.change" -> Ok(AclChange)
    "acl.revoke" -> Ok(AclRevoke)
    "anonymous_access.change" -> Ok(AnonymousAccessChange)
    "delivery.retry" -> Ok(DeliveryRetry)
    "delivery.purge" -> Ok(DeliveryPurge)
    "attachment.delete" -> Ok(AttachmentDelete)
    _ -> Error(Nil)
  }
}

pub fn outcome_name(outcome: Outcome) -> String {
  case outcome {
    Attempted -> "attempted"
    Succeeded -> "succeeded"
    Failed -> "failed"
    Denied -> "denied"
  }
}

pub fn outcome_from_name(value: String) -> Result(Outcome, Nil) {
  case value {
    "attempted" -> Ok(Attempted)
    "succeeded" -> Ok(Succeeded)
    "failed" -> Ok(Failed)
    "denied" -> Ok(Denied)
    _ -> Error(Nil)
  }
}

fn valid_optional_target(target: Option(String)) -> Bool {
  case target {
    None -> True
    Some(value) -> bounded_printable(value, 1, 256)
  }
}

fn valid_status(status: Option(Int)) -> Bool {
  case status {
    None -> True
    Some(value) -> value >= 100 && value <= 599
  }
}

fn bounded_printable(value: String, minimum: Int, maximum: Int) -> Bool {
  let length = string.length(value)
  length >= minimum
  && length <= maximum
  && value
  |> string.to_utf_codepoints
  |> list.all(fn(codepoint) {
    let value = string.utf_codepoint_to_int(codepoint)
    value >= 32 && value != 127
  })
}

fn option_from_result(value: Result(a, Nil)) -> Option(a) {
  case value {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}
