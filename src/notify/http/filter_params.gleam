import gleam/http/request.{type Request}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import notify/core/filter
import notify/core/message
import notify/http/parameter as http_parameter

/// Parse the ntfy query/header aliases used by both poll and live subscribers.
pub fn parse(request: Request(body)) -> Result(filter.Criteria, Nil) {
  use priorities <- result.try(
    parse_priorities(
      parameter(request, [
        "x-priority",
        "priority",
        "prio",
        "p",
      ]),
    ),
  )
  Ok(filter.Criteria(
    id: parameter(request, ["x-id", "id"]),
    message: parameter(request, ["x-message", "message", "m"]),
    title: parameter(request, ["x-title", "title", "t"]),
    priorities:,
    tags: parameter(request, ["x-tags", "tags", "tag", "ta"])
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
  http_parameter.read(request, aliases)
}
