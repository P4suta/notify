import gleam/http/request.{type Request}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import notify/core/filter
import notify/core/message

/// Parse the ntfy query/header aliases used by both poll and live subscribers.
pub fn parse(request: Request(body)) -> Result(filter.Criteria, Nil) {
  use priorities <- result.try(
    parse_priorities(
      parameter(request, [
        "priority",
        "x-priority",
        "p",
      ]),
    ),
  )
  Ok(filter.Criteria(
    id: parameter(request, ["id", "x-id"]),
    message: parameter(request, ["message", "x-message", "m"]),
    title: parameter(request, ["title", "x-title", "t"]),
    priorities:,
    tags: parameter(request, ["tags", "x-tags", "tag", "ta"])
      |> option.map(split_csv)
      |> option.unwrap([]),
  ))
}

fn parse_priorities(
  value: Option(String),
) -> Result(List(message.Priority), Nil) {
  case value {
    None -> Ok([])
    Some(value) ->
      value
      |> split_csv
      |> list.try_map(fn(value) {
        message.parse_priority(value) |> result.map_error(fn(_) { Nil })
      })
  }
}

fn split_csv(value: String) -> List(String) {
  value
  |> string.split(",")
  |> list.map(string.trim)
  |> list.filter(fn(value) { !string.is_empty(value) })
}

fn parameter(request: Request(body), aliases: List(String)) -> Option(String) {
  let query = request.get_query(request) |> result.unwrap([])
  case
    list.find_map(aliases, fn(alias) {
      list.find_map(query, fn(pair) {
        case string.lowercase(pair.0) == alias {
          True -> Ok(pair.1)
          False -> Error(Nil)
        }
      })
    })
  {
    Ok(value) -> Some(value)
    Error(_) ->
      aliases
      |> list.find_map(fn(alias) { request.get_header(request, alias) })
      |> option.from_result
  }
}
