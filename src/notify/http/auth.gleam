import gleam/bit_array
import gleam/http/request.{type Request}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import notify/access.{type Access}
import notify/core/acl
import notify/core/topic.{type Topic}
import notify/security/token

pub type Failure {
  MalformedCredentials
  Unauthenticated
  Forbidden
  SetupRequired
  Unavailable
}

pub fn check(
  request: Request(body),
  control: Access,
  topics: List(Topic),
  operation: acl.Operation,
  now: Int,
) -> Result(acl.Principal, Failure) {
  use credentials <- result.try(
    credentials(request) |> result.map_error(fn(_) { MalformedCredentials }),
  )
  let principal = case access.authenticate(control, credentials, now) {
    Ok(principal) -> Ok(principal)
    // With authentication configured, ntfy rejects an explicitly invalid
    // credential even when the anonymous ACL would permit the operation.
    // OpenAccess already returns Anonymous above and therefore still ignores
    // credentials exactly like an auth-disabled ntfy server.
    Error(access.InvalidCredentials) -> Error(Unauthenticated)
    Error(access.SetupRequired) -> Error(SetupRequired)
    Error(_) -> Error(Unavailable)
  }
  use principal <- result.try(principal)
  authorize(control, principal, topics, operation)
}

fn authorize(
  control: Access,
  principal: acl.Principal,
  topics: List(Topic),
  operation: acl.Operation,
) -> Result(acl.Principal, Failure) {
  case access.authorize(control, principal, topics, operation) {
    Ok(True) -> Ok(principal)
    Ok(False) -> Error(Forbidden)
    Error(access.SetupRequired) -> Error(SetupRequired)
    Error(_) -> Error(Unavailable)
  }
}

pub fn authenticate(
  request: Request(body),
  control: Access,
  now: Int,
) -> Result(acl.Principal, Failure) {
  use required <- result.try(
    access.setup_required(control)
    |> result.map_error(fn(_) { Unavailable }),
  )
  case required {
    True -> Error(SetupRequired)
    False -> {
      use parsed <- result.try(
        credentials(request)
        |> result.map_error(fn(_) { MalformedCredentials }),
      )
      access.authenticate(control, parsed, now)
      |> result.map_error(fn(error) {
        case error {
          access.InvalidCredentials -> Unauthenticated
          access.SetupRequired -> SetupRequired
          _ -> Unavailable
        }
      })
    }
  }
}

pub fn credentials(request: Request(body)) -> Result(access.Credentials, Nil) {
  let direct =
    request.get_header(request, "authorization") |> option.from_result
  let encoded_query = query_parameter(request, "auth")
  let session = session_token(request)
  case direct, encoded_query, session {
    Some(value), _, _ -> parse_authorization(value)
    None, Some(value), _ -> {
      use decoded <- result.try(
        value
        |> bit_array.base64_decode
        |> result.try(bit_array.to_string),
      )
      parse_authorization(decoded)
    }
    None, None, Some(value) -> Ok(access.Bearer(value))
    None, None, None -> Ok(access.NoCredentials)
  }
}

pub fn session_token(request: Request(body)) -> Option(String) {
  request.get_header(request, "cookie")
  |> option.from_result
  |> option.then(fn(header) {
    header
    |> string.split(";")
    |> list.find_map(fn(part) {
      case string.split_once(string.trim(part), "=") {
        Ok(#("notify_session", value)) ->
          case string.is_empty(value) {
            True -> Error(Nil)
            False -> Ok(value)
          }
        _ -> Error(Nil)
      }
    })
    |> option.from_result
  })
}

pub fn uses_session(request: Request(body)) -> Bool {
  request.get_header(request, "authorization") |> result.is_error
  && option.is_none(query_parameter(request, "auth"))
  && option.is_some(session_token(request))
}

pub fn valid_csrf(request: Request(body)) -> Bool {
  case session_token(request), request.get_header(request, "x-csrf-token") {
    Some(session), Ok(presented) ->
      token.secure_equal(presented, token.digest("csrf:" <> session))
    _, _ -> False
  }
}

fn parse_authorization(value: String) -> Result(access.Credentials, Nil) {
  case string.split_once(string.trim(value), " ") {
    Ok(#(scheme, value)) ->
      case string.lowercase(scheme) {
        "bearer" ->
          case string.is_empty(value) {
            True -> Error(Nil)
            False -> Ok(access.Bearer(value))
          }
        "basic" -> {
          use decoded <- result.try(
            value
            |> bit_array.base64_decode
            |> result.try(bit_array.to_string),
          )
          use pair <- result.try(string.split_once(decoded, ":"))
          let #(username, password) = pair
          case
            string.starts_with(username, "tk_"),
            string.is_empty(password),
            string.is_empty(username),
            string.starts_with(password, "tk_")
          {
            True, True, _, _ -> Ok(access.Bearer(username))
            _, _, True, True -> Ok(access.Bearer(password))
            _, _, False, _ -> Ok(access.Basic(username, password))
            _, _, _, _ -> Error(Nil)
          }
        }
        _ -> Error(Nil)
      }

    _ -> Error(Nil)
  }
}

fn query_parameter(request: Request(body), name: String) -> Option(String) {
  request.get_query(request)
  |> result.unwrap([])
  |> list.find_map(fn(pair) {
    case string.lowercase(pair.0) == name {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
  |> option.from_result
}
