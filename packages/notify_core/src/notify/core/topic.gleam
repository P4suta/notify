import gleam/list
import gleam/result
import gleam/string

pub opaque type Topic {
  Topic(String)
}

pub type Error {
  Empty
  TooLong(Int)
  InvalidCharacter(String)
}

pub fn parse(value: String) -> Result(Topic, Error) {
  case string.length(value) {
    0 -> Error(Empty)
    length if length > 64 -> Error(TooLong(length))
    _ -> validate_characters(string.to_graphemes(value), value)
  }
}

fn validate_characters(
  characters: List(String),
  original: String,
) -> Result(Topic, Error) {
  case characters {
    [] -> Ok(Topic(original))
    [character, ..rest] ->
      case is_allowed(character) {
        True -> validate_characters(rest, original)
        False -> Error(InvalidCharacter(character))
      }
  }
}

fn is_allowed(character: String) -> Bool {
  string.contains(
    "-_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789",
    character,
  )
}

pub fn to_string(topic: Topic) -> String {
  let Topic(value) = topic
  value
}

/// Returns whether the topic is reserved by ntfy v2.27.0's default HTTP
/// surface. Keeping this list in the protocol package prevents a publish,
/// poll, or live subscription from shadowing a server route.
pub fn is_disallowed(topic: Topic) -> Bool {
  list.contains(
    [
      "docs",
      "static",
      "file",
      "app",
      "metrics",
      "account",
      "settings",
      "signup",
      "login",
      "v1",
    ],
    to_string(topic),
  )
}

pub fn any_disallowed(topics: List(Topic)) -> Bool {
  list.any(topics, is_disallowed)
}

pub fn parse_many(value: String) -> Result(List(Topic), Error) {
  value
  |> string.split(",")
  |> parse_many_loop([])
}

fn parse_many_loop(
  remaining: List(String),
  parsed: List(Topic),
) -> Result(List(Topic), Error) {
  case remaining {
    [] -> Ok(list.reverse(parsed))
    [value, ..rest] -> {
      use topic <- result.try(parse(value))
      case list.contains(parsed, topic) {
        True -> parse_many_loop(rest, parsed)
        False -> parse_many_loop(rest, [topic, ..parsed])
      }
    }
  }
}

pub fn many_to_strings(topics: List(Topic)) -> List(String) {
  list.map(topics, to_string)
}
