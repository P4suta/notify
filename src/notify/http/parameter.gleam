import gleam/http/request.{type Request}
import gleam/list
import gleam/option.{type Option, Some}
import gleam/result
import gleam/string

/// Reads an ntfy parameter with the same precedence as the pinned server:
/// headers before query parameters, and aliases in the order supplied.
/// Empty values are ignored so a later alias or query value can be used.
pub fn read(request: Request(body), aliases: List(String)) -> Option(String) {
  case
    list.find_map(aliases, fn(alias) {
      case request.get_header(request, alias) {
        Ok(value) -> non_empty_header(alias, value)
        Error(_) -> Error(Nil)
      }
    })
  {
    Ok(value) -> Some(value)
    Error(_) -> {
      let query = request.get_query(request) |> result.unwrap([])
      aliases
      |> list.find_map(fn(alias) {
        list.find_map(query, fn(pair) {
          case pair.0 == string.lowercase(alias) {
            True -> non_empty(pair.1)
            False -> Error(Nil)
          }
        })
      })
      |> option.from_result
    }
  }
}

fn non_empty_header(alias: String, value: String) -> Result(String, Nil) {
  let value = string.trim(value)
  case string.lowercase(alias) == "priority" && is_rfc_9218_priority(value) {
    True -> Error(Nil)
    False -> non_empty(value)
  }
}

// ntfy v2.27.0 ignores the standard HTTP Priority header when it has one of
// the RFC 9218 shapes browsers and proxies commonly add. This applies only to
// the plain Priority header; X-Priority and query aliases remain ntfy values.
fn is_rfc_9218_priority(value: String) -> Bool {
  case string.split_once(value, on: ",") {
    Error(_) -> is_rfc_9218_urgency(value)
    Ok(#(urgency, incremental)) -> {
      let incremental = string.trim(incremental)
      is_rfc_9218_urgency(urgency)
      && { incremental == "i" || is_single_digit(incremental) }
    }
  }
}

fn is_rfc_9218_urgency(value: String) -> Bool {
  string.starts_with(value, "u=")
  && is_single_digit(string.drop_start(value, 2))
}

fn is_single_digit(value: String) -> Bool {
  list.contains(["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"], value)
}

fn non_empty(value: String) -> Result(String, Nil) {
  let value = string.trim(value)
  case string.is_empty(value) {
    True -> Error(Nil)
    False -> Ok(value)
  }
}
