import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri
import notify/core/topic

pub const max_topics = 50

pub type NewSubscription {
  NewSubscription(
    id: String,
    endpoint: String,
    auth: String,
    p256dh: String,
    topics: List(String),
    user_id: Option(String),
    subscriber_ip: String,
    now: Int,
  )
}

pub type Subscription {
  Subscription(
    id: String,
    endpoint: String,
    auth: String,
    p256dh: String,
    topics: List(String),
    user_id: Option(String),
    subscriber_ip: String,
    created_at: Int,
    updated_at: Int,
  )
}

pub type Error {
  InvalidSubscription
  UnknownEndpoint
  TooManyTopics
  TooManySubscriptions
  NotFound
  Conflict
  Unavailable(String)
}

pub type Store {
  Store(
    upsert: fn(NewSubscription) -> Result(Subscription, Error),
    for_topic: fn(String) -> Result(List(Subscription), Error),
    by_endpoint: fn(String) -> Result(Subscription, Error),
    remove_endpoint: fn(String) -> Result(Nil, Error),
    remove_user: fn(String) -> Result(Int, Error),
    remove_expired: fn(Int) -> Result(Int, Error),
    health: fn() -> Result(Nil, Error),
  )
}

pub fn validate(subscription: NewSubscription) -> Result(Nil, Error) {
  case
    string.is_empty(string.trim(subscription.id))
    || string.is_empty(string.trim(subscription.auth))
    || string.is_empty(string.trim(subscription.p256dh))
    || string.is_empty(string.trim(subscription.subscriber_ip)),
    endpoint_allowed(subscription.endpoint),
    list.length(subscription.topics) > max_topics,
    list.all(subscription.topics, fn(value) {
      topic.parse(value) |> result.is_ok
    })
  {
    True, _, _, _ -> Error(InvalidSubscription)
    _, False, _, _ -> Error(UnknownEndpoint)
    _, _, True, _ -> Error(TooManyTopics)
    _, _, _, False -> Error(InvalidSubscription)
    _, _, _, _ -> validate_keys(subscription.auth, subscription.p256dh)
  }
}

fn validate_keys(auth: String, p256dh: String) -> Result(Nil, Error) {
  case bit_array.base64_url_decode(auth), bit_array.base64_url_decode(p256dh) {
    Ok(auth_bytes), Ok(public_key) ->
      case
        bit_array.byte_size(auth_bytes) == 16
        && bit_array.byte_size(public_key) == 65
        && bit_array.starts_with(public_key, <<4>>)
      {
        True -> Ok(Nil)
        False -> Error(InvalidSubscription)
      }
    _, _ -> Error(InvalidSubscription)
  }
}

pub fn from_new(value: NewSubscription) -> Subscription {
  Subscription(
    id: value.id,
    endpoint: value.endpoint,
    auth: value.auth,
    p256dh: value.p256dh,
    topics: list.unique(value.topics),
    user_id: value.user_id,
    subscriber_ip: value.subscriber_ip,
    created_at: value.now,
    updated_at: value.now,
  )
}

/// Restricts push delivery to the service hosts accepted by ntfy v2.27.0.
/// Matching the parsed authority, rather than a substring, prevents the
/// endpoint confusion/SSRF class covered by GHSA-w9hq-5jg7-q4j7.
pub fn endpoint_allowed(endpoint: String) -> Bool {
  case uri.parse(endpoint) {
    Error(_) -> False
    Ok(parsed) ->
      case parsed.scheme, parsed.host, parsed.userinfo, parsed.port {
        Some("https"), Some(host), None, None ->
          string.starts_with(parsed.path, "/") && allowed_host(host)
        _, _, _, _ -> False
      }
  }
}

fn allowed_host(host: String) -> Bool {
  let host = string.lowercase(host)
  list.contains(
    [
      "fcm.googleapis.com",
      "jmt17.google.com",
      "updates.push.services.mozilla.com",
      "web.push.apple.com",
    ],
    host,
  )
  || single_label_suffix(host, ".mozaws.net")
  || single_label_suffix(host, ".notify.windows.com")
}

fn single_label_suffix(host: String, suffix: String) -> Bool {
  case string.ends_with(host, suffix) {
    False -> False
    True -> {
      let prefix = string.drop_end(host, string.length(suffix))
      !string.is_empty(prefix) && !string.contains(prefix, ".")
    }
  }
}

pub fn user_id_string(user_id: Option(String)) -> String {
  user_id |> option.unwrap("")
}

pub fn optional_user_id(user_id: String) -> Option(String) {
  case string.is_empty(user_id) {
    True -> None
    False -> Some(user_id)
  }
}
