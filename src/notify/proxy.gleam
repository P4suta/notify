import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

/// Returns the effective client address for a request.
///
/// Forwarding headers are ignored unless the socket peer is explicitly listed
/// as a trusted proxy. This prevents clients from choosing the address used by
/// rate limits and audit records.
pub fn client_ip(
  peer: String,
  trusted_proxies: List(String),
  x_forwarded_for: Option(String),
  forwarded: Option(String),
) -> String {
  case list.any(trusted_proxies, same_address(peer, _)) {
    False -> peer
    True ->
      case first_x_forwarded_address(x_forwarded_for) {
        Some(address) -> address
        None ->
          forwarded
          |> forwarded_address
          |> option.unwrap(peer)
      }
  }
}

pub fn valid_address(value: String) -> Bool {
  let value = string.trim(value)
  !string.is_empty(value)
  && string.length(value) <= 45
  && valid_ip_address(value)
}

fn same_address(peer: String, trusted: String) -> Bool {
  same_ip_address(string.trim(peer), string.trim(trusted))
}

fn first_x_forwarded_address(value: Option(String)) -> Option(String) {
  case value {
    None -> None
    Some(value) ->
      case value |> string.split(",") |> list.first {
        Error(_) -> None
        Ok(address) -> parse_address_value(address)
      }
  }
}

fn forwarded_address(value: Option(String)) -> Option(String) {
  case value {
    None -> None
    Some(value) ->
      case value |> string.split(",") |> list.first {
        Error(_) -> None
        Ok(element) -> find_for_parameter(string.split(element, ";"))
      }
  }
}

fn find_for_parameter(parameters: List(String)) -> Option(String) {
  case parameters {
    [] -> None
    [parameter, ..rest] ->
      case string.split_once(parameter, "=") {
        Ok(#(name, value)) ->
          case string.lowercase(string.trim(name)) == "for" {
            True -> parse_address_value(value)
            False -> find_for_parameter(rest)
          }
        Error(_) -> find_for_parameter(rest)
      }
  }
}

fn parse_address_value(raw: String) -> Option(String) {
  let value = raw |> string.trim |> unquote
  case string.starts_with(value, "[") {
    True -> parse_bracketed_address(value)
    False ->
      case valid_address(value) {
        True -> Some(value)
        False -> parse_ipv4_with_port(value)
      }
  }
}

fn parse_bracketed_address(value: String) -> Option(String) {
  case value |> string.drop_start(1) |> string.split_once("]") {
    Error(_) -> None
    Ok(#(address, suffix)) ->
      case valid_address(address) && valid_port_suffix(suffix) {
        True -> Some(address)
        False -> None
      }
  }
}

fn parse_ipv4_with_port(value: String) -> Option(String) {
  case string.split_once(value, ":") {
    Ok(#(address, port)) ->
      case valid_address(address), valid_port(port) {
        True, True -> Some(address)
        _, _ -> None
      }
    Error(_) -> None
  }
}

fn valid_port_suffix(suffix: String) -> Bool {
  case suffix {
    "" -> True
    _ ->
      case string.starts_with(suffix, ":") {
        True -> suffix |> string.drop_start(1) |> valid_port
        False -> False
      }
  }
}

fn valid_port(value: String) -> Bool {
  case int.parse(value) {
    Ok(port) -> port >= 1 && port <= 65_535
    Error(_) -> False
  }
}

fn unquote(value: String) -> String {
  case string.starts_with(value, "\"") && string.ends_with(value, "\"") {
    True -> value |> string.drop_start(1) |> string.drop_end(1)
    False -> value
  }
}

@external(erlang, "notify_ffi", "valid_ip_address")
fn valid_ip_address(value: String) -> Bool

@external(erlang, "notify_ffi", "same_ip_address")
fn same_ip_address(first: String, second: String) -> Bool
