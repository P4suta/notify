import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import notify/core/message
import notify/storage

pub type Error {
  InvalidSince
}

/// Parses ntfy's subscription cursor forms. An omitted cursor means all cached
/// messages for polling, and no replay for a live connection.
pub fn parse(
  value: Option(String),
  poll poll: Bool,
  now now: Int,
) -> Result(storage.Since, Error) {
  case value {
    None ->
      case poll {
        True -> Ok(storage.All)
        False -> Ok(storage.NoneSince)
      }
    Some(raw) -> parse_value(string.trim(raw), now)
  }
}

fn parse_value(value: String, now: Int) -> Result(storage.Since, Error) {
  let lower = string.lowercase(value)
  case lower {
    "all" -> Ok(storage.All)
    "none" -> Ok(storage.NoneSince)
    "latest" -> Ok(storage.Latest)
    _ ->
      case message.valid_id(value), int.parse(value) {
        True, _ -> Ok(storage.AfterId(value))
        False, Ok(timestamp) -> Ok(storage.AfterTime(timestamp))
        False, Error(_) ->
          parse_duration(lower)
          |> result.map(fn(seconds) { storage.AfterTime(now - seconds) })
      }
  }
}

fn parse_duration(value: String) -> Result(Int, Error) {
  let units = [
    #("µs", 0.000001),
    #("us", 0.000001),
    #("ns", 0.000000001),
    #("ms", 0.001),
    #("h", 3600.0),
    #("m", 60.0),
    #("s", 1.0),
  ]
  units
  |> list.find_map(fn(unit) {
    case string.ends_with(value, unit.0) {
      False -> Error(Nil)
      True -> {
        let amount =
          value
          |> string.drop_end(string.length(unit.0))
          |> float.parse
        case amount {
          Ok(amount) ->
            case amount >=. 0.0 {
              True -> Ok(float.truncate(amount *. unit.1))
              False -> Error(Nil)
            }
          Error(_) -> Error(Nil)
        }
      }
    }
  })
  |> result.map_error(fn(_) { InvalidSince })
}
