import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import notify/core/message.{type Action}
import notify/core/message_json

pub type Error {
  InvalidSyntax
  InvalidAction
  InvalidActionKind(String)
  TooManyActions
}

type Settings {
  Settings(
    kind: Option(String),
    label: Option(String),
    url: Option(String),
    method: Option(String),
    headers: List(#(String, String)),
    body: Option(String),
    value: Option(String),
    clear: Bool,
  )
}

pub fn parse(input: String) -> Result(List(Action), Error) {
  let input = string.trim(input)
  case input {
    "" -> Ok([])
    value -> {
      case string.starts_with(value, "[") {
        True ->
          message_json.decode_actions(value)
          |> result.map_error(fn(_) { InvalidAction })
          |> result.map(validate_actions)
          |> result.flatten
        False -> {
          use groups <- result.try(split_aware_with(value, ";", True))
          case list.length(groups) > 3 {
            True -> Error(TooManyActions)
            False ->
              groups
              |> list.try_map(parse_simple)
              |> result.map(validate_actions)
              |> result.flatten
          }
        }
      }
    }
  }
}

fn parse_simple(input: String) -> Result(Action, Error) {
  use terms <- result.try(split_aware(input, ","))
  use settings <- result.try(populate(terms, 0, empty_settings()))
  settings_to_action(settings)
}

fn empty_settings() -> Settings {
  Settings(
    kind: None,
    label: None,
    url: None,
    method: None,
    headers: [],
    body: None,
    value: None,
    clear: False,
  )
}

fn populate(
  terms: List(String),
  index: Int,
  settings: Settings,
) -> Result(Settings, Error) {
  case terms {
    [] -> Ok(settings)
    [raw, ..rest] -> {
      let term = string.trim(raw)
      use updated <- result.try(case explicit_pair(term) {
        Some(#(key, value)) -> set_explicit(settings, key, value)
        None -> set_positional(settings, index, term)
      })
      populate(rest, index + 1, updated)
    }
  }
}

fn explicit_pair(value: String) -> Option(#(String, String)) {
  case string.split_once(value, "=") {
    Error(_) -> None
    Ok(#(raw_key, raw_value)) -> {
      let key = raw_key |> string.trim |> string.lowercase
      case
        list.contains(
          ["action", "label", "clear", "url", "method", "body", "value"],
          key,
        )
        || string.starts_with(key, "headers.")
      {
        True -> Some(#(string.trim(raw_key), string.trim(raw_value)))
        False -> None
      }
    }
  }
}

fn set_explicit(
  settings: Settings,
  raw_key: String,
  value: String,
) -> Result(Settings, Error) {
  let key = string.lowercase(raw_key)
  case key {
    "action" -> Ok(Settings(..settings, kind: Some(string.lowercase(value))))
    "label" -> Ok(Settings(..settings, label: Some(value)))
    "url" -> Ok(Settings(..settings, url: Some(value)))
    "method" -> Ok(Settings(..settings, method: Some(string.uppercase(value))))
    "body" -> Ok(Settings(..settings, body: Some(value)))
    "value" -> Ok(Settings(..settings, value: Some(value)))
    "clear" ->
      case string.lowercase(value) {
        "true" | "yes" | "1" -> Ok(Settings(..settings, clear: True))
        "false" | "no" | "0" -> Ok(Settings(..settings, clear: False))
        _ -> Error(InvalidAction)
      }
    _ -> {
      // `explicit_pair` only routes recognised `headers.*` keys here.
      let name = raw_key |> string.drop_start(8) |> string.trim
      case string.is_empty(name) {
        True -> Error(InvalidAction)
        False ->
          Ok(
            Settings(..settings, headers: [#(name, value), ..settings.headers]),
          )
      }
    }
  }
}

fn set_positional(
  settings: Settings,
  index: Int,
  value: String,
) -> Result(Settings, Error) {
  case index, settings.kind {
    0, _ -> Ok(Settings(..settings, kind: Some(string.lowercase(value))))
    1, _ -> Ok(Settings(..settings, label: Some(value)))
    2, Some("copy") -> Ok(Settings(..settings, value: Some(value)))
    2, Some("view") | 2, Some("http") ->
      Ok(Settings(..settings, url: Some(value)))
    _, _ -> Error(InvalidAction)
  }
}

fn settings_to_action(settings: Settings) -> Result(Action, Error) {
  case settings.kind, settings.label, settings.url, settings.value {
    Some("view"), Some(label), Some(url), _ ->
      Ok(message.ViewAction(label:, url:, clear: settings.clear, id: None))
    Some("http"), Some(label), Some(url), _ ->
      Ok(message.HttpAction(
        label:,
        url:,
        method: settings.method |> option.unwrap("POST"),
        headers: list.reverse(settings.headers),
        body: settings.body,
        clear: settings.clear,
        id: None,
      ))
    Some("copy"), Some(label), _, Some(value) ->
      Ok(message.CopyAction(label:, value:, clear: settings.clear, id: None))
    Some("view"), _, _, _ | Some("http"), _, _, _ | Some("copy"), _, _, _ ->
      Error(InvalidAction)
    Some(kind), _, _, _ -> Error(InvalidActionKind(kind))
    _, _, _, _ -> Error(InvalidAction)
  }
}

fn validate_actions(actions: List(Action)) -> Result(List(Action), Error) {
  case list.length(actions) > 3 {
    True -> Error(TooManyActions)
    False ->
      case list.all(actions, valid_action) {
        True -> Ok(actions)
        False -> Error(InvalidAction)
      }
  }
}

fn valid_action(action: Action) -> Bool {
  case action {
    message.ViewAction(label, url, _, _) ->
      !string.is_empty(label) && !string.is_empty(url)
    message.CopyAction(label, value, _, _) ->
      !string.is_empty(label) && !string.is_empty(value)
    message.HttpAction(label, url, method, _, body, _, _) ->
      !string.is_empty(label)
      && !string.is_empty(url)
      && valid_http_body(method, body)
  }
}

fn valid_http_body(method: String, body: Option(String)) -> Bool {
  case list.contains(["GET", "HEAD"], string.uppercase(method)), body {
    True, Some(_) -> False
    _, _ -> True
  }
}

fn split_aware(
  input: String,
  separator: String,
) -> Result(List(String), Error) {
  split_aware_with(input, separator, False)
}

fn split_aware_with(
  input: String,
  separator: String,
  preserve_quotes: Bool,
) -> Result(List(String), Error) {
  split_loop(
    string.to_graphemes(input),
    separator,
    preserve_quotes,
    current: [],
    values: [],
    quote: None,
    escaped: False,
  )
}

fn split_loop(
  remaining: List(String),
  separator: String,
  preserve_quotes: Bool,
  current current: List(String),
  values values: List(String),
  quote quote: Option(String),
  escaped escaped: Bool,
) -> Result(List(String), Error) {
  case remaining, quote, escaped {
    [], Some(_), _ -> Error(InvalidSyntax)
    [], None, _ ->
      Ok(
        [current |> list.reverse |> string.concat, ..values]
        |> list.reverse,
      )
    [character, ..rest], Some(active), True ->
      split_loop(
        rest,
        separator,
        preserve_quotes,
        [character, ..current],
        values,
        Some(active),
        False,
      )
    ["\\", ..rest], Some(active), False ->
      split_loop(
        rest,
        separator,
        preserve_quotes,
        case preserve_quotes {
          True -> ["\\", ..current]
          False -> current
        },
        values,
        Some(active),
        True,
      )
    [character, ..rest], Some(active), False if character == active ->
      split_loop(
        rest,
        separator,
        preserve_quotes,
        case preserve_quotes {
          True -> [character, ..current]
          False -> current
        },
        values,
        None,
        False,
      )
    [character, ..rest], Some(active), False ->
      split_loop(
        rest,
        separator,
        preserve_quotes,
        [character, ..current],
        values,
        Some(active),
        False,
      )
    [character, ..rest], None, False if character == "\"" || character == "'" ->
      split_loop(
        rest,
        separator,
        preserve_quotes,
        case preserve_quotes {
          True -> [character, ..current]
          False -> current
        },
        values,
        Some(character),
        False,
      )
    [character, ..rest], None, False if character == separator ->
      split_loop(
        rest,
        separator,
        preserve_quotes,
        current: [],
        values: [current |> list.reverse |> string.concat, ..values],
        quote: None,
        escaped: False,
      )
    [character, ..rest], None, False ->
      split_loop(
        rest,
        separator,
        preserve_quotes,
        [character, ..current],
        values,
        None,
        False,
      )
    _, None, True -> Error(InvalidSyntax)
  }
}
