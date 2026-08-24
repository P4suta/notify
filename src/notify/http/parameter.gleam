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
        Ok(value) -> non_empty(value)
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

fn non_empty(value: String) -> Result(String, Nil) {
  let value = string.trim(value)
  case string.is_empty(value) {
    True -> Error(Nil)
    False -> Ok(value)
  }
}
