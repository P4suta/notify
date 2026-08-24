import gleam/int
import gleam/list
import gleam/result
import gleam/string

pub type Error {
  InvalidDelay
  NotInFuture
  TooSoon(minimum_seconds: Int)
  TooFar(maximum_seconds: Int)
}

pub const minimum_seconds = 10

pub const maximum_seconds = 259_200

/// Resolves the ntfy delay forms that are deterministic without locale data:
/// a future Unix timestamp or an integer followed by seconds, minutes, hours,
/// or days (short and long spellings are accepted).
pub fn resolve(value: String, now now: Int) -> Result(Int, Error) {
  let normalised =
    value
    |> string.lowercase
    |> string.replace(" ", "")
  case int.parse(normalised) {
    Ok(timestamp) -> ensure_future(timestamp, now)
    Error(_) -> {
      use seconds <- result.try(parse_duration(normalised))
      ensure_future(now + seconds, now)
    }
  }
}

fn parse_duration(value: String) -> Result(Int, Error) {
  let units = [
    #("seconds", 1),
    #("second", 1),
    #("secs", 1),
    #("sec", 1),
    #("minutes", 60),
    #("minute", 60),
    #("mins", 60),
    #("min", 60),
    #("hours", 3600),
    #("hour", 3600),
    #("hrs", 3600),
    #("hr", 3600),
    #("days", 86_400),
    #("day", 86_400),
    #("s", 1),
    #("m", 60),
    #("h", 3600),
    #("d", 86_400),
  ]
  units
  |> list.find_map(fn(unit) {
    case string.ends_with(value, unit.0) {
      False -> Error(Nil)
      True ->
        value
        |> string.drop_end(string.length(unit.0))
        |> int.parse
        |> result.map(fn(amount) { amount * unit.1 })
    }
  })
  |> result.map_error(fn(_) { InvalidDelay })
}

fn ensure_future(timestamp: Int, now: Int) -> Result(Int, Error) {
  let seconds = timestamp - now
  case seconds {
    seconds if seconds <= 0 -> Error(NotInFuture)
    seconds if seconds < minimum_seconds -> Error(TooSoon(minimum_seconds))
    seconds if seconds > maximum_seconds -> Error(TooFar(maximum_seconds))
    _ -> Ok(timestamp)
  }
}
