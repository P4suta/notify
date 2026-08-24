import gleam/bit_array
import gleam/dynamic/decode
import gleam/http.{Delete, Get, Patch, Post, Put}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import notify/access
import notify/core/acl
import notify/http/auth
import notify/identity
import notify/runtime.{type Runtime}
import notify/security/token
import notify/storage

const auth_docs = "https://ntfy.sh/docs/publish/#authentication"

type UserMutation {
  UserMutation(
    username: String,
    password: String,
    password_hash: String,
    tier: String,
  )
}

type UserDelete {
  UserDelete(username: String)
}

type AccessMutation {
  AccessMutation(username: String, topic: String, permission: String)
}

type PasswordMutation {
  PasswordMutation(password: String, new_password: String)
}

type AccountDelete {
  AccountDelete(password: String)
}

type TokenIssue {
  TokenIssue(label: String, expires: Option(Int))
}

pub fn route(
  request: Request(BitArray),
  runtime: Runtime,
) -> Option(Response(BitArray)) {
  case request.method, request.path_segments(request) {
    Get, ["v1", "account"] -> Some(account_get(request, runtime))
    Delete, ["v1", "account"] ->
      Some(
        with_user(request, runtime, True, fn(username) {
          account_delete(request, username, runtime)
        }),
      )
    Post, ["v1", "account", "login"] ->
      Some(
        with_user(request, runtime, False, fn(username) {
          account_login(username, runtime)
        }),
      )
    Post, ["v1", "account", "password"] ->
      Some(
        with_user(request, runtime, True, fn(username) {
          account_password(request, username, runtime)
        }),
      )
    Post, ["v1", "account", "token"] ->
      Some(
        with_user(request, runtime, True, fn(username) {
          account_token_create(request, username, runtime)
        }),
      )
    Delete, ["v1", "account", "token"] ->
      Some(
        with_user(request, runtime, True, fn(username) {
          account_token_delete(request, username, runtime)
        }),
      )
    Patch, ["v1", "account", "token"] ->
      Some(
        with_user(request, runtime, True, fn(_) {
          ntfy_error(
            400,
            40_023,
            "invalid request: token updates are not supported; revoke and create a replacement",
            "",
          )
        }),
      )
    Get, ["v1", "users"] ->
      Some(with_admin(request, runtime, False, fn() { users_get(runtime) }))
    Post, ["v1", "users"] ->
      Some(
        with_admin(request, runtime, True, fn() {
          users_create(request, runtime)
        }),
      )
    Put, ["v1", "users"] ->
      Some(
        with_admin(request, runtime, True, fn() {
          users_update(request, runtime)
        }),
      )
    Delete, ["v1", "users"] ->
      Some(
        with_admin(request, runtime, True, fn() {
          users_delete(request, runtime)
        }),
      )
    Post, ["v1", "users", "access"] | Put, ["v1", "users", "access"] ->
      Some(
        with_admin(request, runtime, True, fn() {
          users_access_put(request, runtime)
        }),
      )
    Delete, ["v1", "users", "access"] ->
      Some(
        with_admin(request, runtime, True, fn() {
          users_access_delete(request, runtime)
        }),
      )
    _, _ -> None
  }
}

fn account_get(
  request: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  let runtime.Clock(now) = runtime.clock
  case auth.authenticate(request, runtime.access, now()) {
    Error(auth.SetupRequired) -> unavailable("server setup is required")
    Error(auth.MalformedCredentials) | Error(auth.Unauthenticated) ->
      unauthorized()
    Error(_) -> unavailable("authorization unavailable")
    Ok(principal) ->
      case runtime.storage.stats() {
        Error(_) -> unavailable("storage unavailable")
        Ok(statistics) -> {
          let #(username, role) = principal_identity(principal)
          let token_json = case principal {
            acl.Anonymous -> []
            acl.Authenticated(username, _) ->
              access.list_tokens(runtime.access, username)
              |> result.unwrap([])
              |> list.map(stored_token_json)
          }
          json_response(
            200,
            json.object([
              #("username", json.string(username)),
              #("role", json.string(role)),
              #("tokens", json.array(token_json, fn(value) { value })),
              #(
                "limits",
                json.object([
                  #("basis", json.string("ip")),
                  #("messages", json.int(0)),
                  #(
                    "messages_expiry_duration",
                    json.int(runtime.retention_seconds),
                  ),
                  #("emails", json.int(0)),
                  #("calls", json.int(0)),
                  #("reservations", json.int(0)),
                  #(
                    "attachment_total_size",
                    json.int(runtime.attachment_total_size_bytes),
                  ),
                  #(
                    "attachment_file_size",
                    json.int(runtime.attachment_file_size_bytes),
                  ),
                  #(
                    "attachment_expiry_duration",
                    json.int(runtime.attachment_retention_seconds),
                  ),
                  #("attachment_bandwidth", json.int(0)),
                ]),
              ),
              #("stats", account_stats(statistics)),
            ]),
          )
        }
      }
  }
}

fn account_stats(statistics: storage.Stats) -> json.Json {
  json.object([
    #("messages", json.int(statistics.messages)),
    #("messages_remaining", json.int(0)),
    #("emails", json.int(0)),
    #("emails_remaining", json.int(0)),
    #("calls", json.int(0)),
    #("calls_remaining", json.int(0)),
    #("reservations", json.int(0)),
    #("reservations_remaining", json.int(0)),
    #("attachment_total_size", json.int(0)),
    #("attachment_total_size_remaining", json.int(0)),
  ])
}

fn account_login(username: String, runtime: Runtime) -> Response(BitArray) {
  let runtime.Clock(now) = runtime.clock
  let runtime.IdGenerator(next_id) = runtime.ids
  case
    access.create_token_for_username(
      runtime.access,
      "tok_" <> next_id(),
      username,
      "",
      Some(now() + 259_200),
      now(),
      token.secure_entropy,
    )
  {
    Ok(#(_, raw)) ->
      json_response(
        200,
        json.object([
          #("token", json.string(raw)),
          #("username", json.string(username)),
        ]),
      )
    Error(_) -> unavailable("token storage unavailable")
  }
}

fn account_token_create(
  request: Request(BitArray),
  username: String,
  runtime: Runtime,
) -> Response(BitArray) {
  use issued <- parse_optional_json(request, token_issue_decoder())
  let runtime.Clock(now) = runtime.clock
  let runtime.IdGenerator(next_id) = runtime.ids
  let expires = issued.expires |> option_or(Some(now() + 259_200))
  case
    access.create_token_for_username(
      runtime.access,
      "tok_" <> next_id(),
      username,
      issued.label,
      expires,
      now(),
      token.secure_entropy,
    )
  {
    Ok(#(stored, raw)) -> json_response(200, issued_token_json(raw, stored))
    Error(access.InvalidTokenLabel) ->
      invalid_request(
        40_024,
        "invalid request: request body must be valid JSON",
      )
    Error(_) -> unavailable("token storage unavailable")
  }
}

fn account_token_delete(
  request: Request(BitArray),
  username: String,
  runtime: Runtime,
) -> Response(BitArray) {
  let raw = token_to_delete(request)
  case raw {
    None -> invalid_request(40_023, "invalid request: no token provided")
    Some(raw) -> {
      let runtime.Clock(now) = runtime.clock
      case access.authenticate(runtime.access, access.Bearer(raw), now()) {
        Ok(acl.Authenticated(owner, _)) if owner == username ->
          case access.revoke_raw_token(runtime.access, raw) {
            Ok(_) -> success()
            Error(_) -> unavailable("token storage unavailable")
          }
        _ -> unauthorized()
      }
    }
  }
}

fn account_password(
  request: Request(BitArray),
  username: String,
  runtime: Runtime,
) -> Response(BitArray) {
  use changed <- parse_json(request, password_decoder())
  let runtime.Clock(now) = runtime.clock
  case
    access.authenticate(
      runtime.access,
      access.Basic(username, changed.password),
      now(),
    )
  {
    Ok(_) ->
      case
        access.change_password(runtime.access, username, changed.new_password)
      {
        Ok(_) -> success()
        Error(access.PasswordError(_)) ->
          invalid_request(40_024, "invalid request: new password is invalid")
        Error(_) -> unavailable("identity storage unavailable")
      }
    Error(_) ->
      invalid_request(
        40_026,
        "invalid request: password confirmation is not correct",
      )
  }
}

fn account_delete(
  request: Request(BitArray),
  username: String,
  runtime: Runtime,
) -> Response(BitArray) {
  use deletion <- parse_json(request, account_delete_decoder())
  let runtime.Clock(now) = runtime.clock
  case
    access.authenticate(
      runtime.access,
      access.Basic(username, deletion.password),
      now(),
    )
  {
    Error(_) ->
      invalid_request(
        40_026,
        "invalid request: password confirmation is not correct",
      )
    Ok(_) ->
      case access.delete_user(runtime.access, username) {
        Ok(_) -> {
          case runtime.webpush {
            None -> Nil
            Some(configured) -> {
              let _ = configured.store.remove_user(username)
              Nil
            }
          }
          success()
        }
        Error(access.LastAdmin) ->
          ntfy_error(
            409,
            40_905,
            "conflict: cannot delete the final administrator",
            "",
          )
        Error(_) -> unavailable("identity storage unavailable")
      }
  }
}

fn users_get(runtime: Runtime) -> Response(BitArray) {
  case
    access.list_users(runtime.access),
    access.list_grants(runtime.access, None)
  {
    Ok(users), Ok(grants) ->
      json_response(
        200,
        json.array(users, fn(user) { user_json(user, grants) }),
      )
    _, _ -> unavailable("identity storage unavailable")
  }
}

fn users_create(
  request: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  use mutation <- parse_json(request, user_mutation_decoder())
  case mutation.password_hash, mutation.password, mutation.tier {
    hash, _, _ if hash != "" ->
      invalid_request(
        40_024,
        "invalid request: password hash provisioning is available only through notify migrate ntfy",
      )
    _, _, tier if tier != "" ->
      invalid_request(40_030, "invalid request: tier does not exist")
    _, "", _ ->
      invalid_request(
        40_024,
        "invalid request: username invalid, or password missing",
      )
    _, password, _ -> {
      let runtime.Clock(now) = runtime.clock
      let runtime.IdGenerator(next_id) = runtime.ids
      case
        access.add_user(
          runtime.access,
          "u_" <> next_id(),
          mutation.username,
          password,
          acl.User,
          now(),
        )
      {
        Ok(_) -> success()
        Error(access.IdentityError(identity.Conflict(_))) ->
          ntfy_error(409, 40_901, "conflict: user already exists", "")
        Error(access.InvalidUsername) | Error(access.PasswordError(_)) ->
          invalid_request(
            40_024,
            "invalid request: username invalid, or password missing",
          )
        Error(_) -> unavailable("identity storage unavailable")
      }
    }
  }
}

fn users_update(
  request: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  use mutation <- parse_json(request, user_mutation_decoder())
  case mutation.password_hash, mutation.tier {
    hash, _ if hash != "" ->
      invalid_request(
        40_024,
        "invalid request: password hash provisioning is available only through notify migrate ntfy",
      )
    _, tier if tier != "" ->
      invalid_request(40_030, "invalid request: tier does not exist")
    _, _ ->
      case access.user_by_name(runtime.access, mutation.username) {
        Ok(user) if user.role == acl.Admin -> forbidden()
        Ok(_) ->
          case mutation.password {
            "" ->
              invalid_request(40_024, "invalid request: password is required")
            password ->
              case
                access.change_password(
                  runtime.access,
                  mutation.username,
                  password,
                )
              {
                Ok(_) -> success()
                Error(access.PasswordError(_)) ->
                  invalid_request(
                    40_024,
                    "invalid request: password is invalid",
                  )
                Error(_) -> unavailable("identity storage unavailable")
              }
          }
        Error(access.IdentityError(identity.NotFound)) ->
          users_create_from_mutation(mutation, runtime)
        Error(_) -> unavailable("identity storage unavailable")
      }
  }
}

fn users_create_from_mutation(
  mutation: UserMutation,
  runtime: Runtime,
) -> Response(BitArray) {
  case mutation.password {
    "" -> invalid_request(40_024, "invalid request: password is required")
    password -> {
      let runtime.Clock(now) = runtime.clock
      let runtime.IdGenerator(next_id) = runtime.ids
      case
        access.add_user(
          runtime.access,
          "u_" <> next_id(),
          mutation.username,
          password,
          acl.User,
          now(),
        )
      {
        Ok(_) -> success()
        Error(access.InvalidUsername) | Error(access.PasswordError(_)) ->
          invalid_request(40_024, "invalid request: invalid user")
        Error(_) -> unavailable("identity storage unavailable")
      }
    }
  }
}

fn users_delete(
  request: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  use deletion <- parse_json(request, user_delete_decoder())
  case access.user_by_name(runtime.access, deletion.username) {
    Ok(user) if user.role != acl.User -> unauthorized()
    Ok(_) ->
      case access.delete_user(runtime.access, deletion.username) {
        Ok(_) -> {
          case runtime.webpush {
            None -> Nil
            Some(configured) -> {
              let _ = configured.store.remove_user(deletion.username)
              Nil
            }
          }
          success()
        }
        Error(_) -> unavailable("identity storage unavailable")
      }
    Error(access.IdentityError(identity.NotFound)) ->
      invalid_request(40_031, "invalid request: user does not exist")
    Error(_) -> unavailable("identity storage unavailable")
  }
}

fn users_access_put(
  request: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  use mutation <- parse_json(request, access_mutation_decoder())
  case parse_permission(mutation.permission) {
    Error(_) ->
      invalid_request(40_025, "invalid request: incorrect permission string")
    Ok(permission) ->
      case access.user_by_name(runtime.access, mutation.username) {
        Error(access.IdentityError(identity.NotFound)) ->
          invalid_request(40_031, "invalid request: user does not exist")
        Error(_) -> unavailable("identity storage unavailable")
        Ok(_) ->
          case
            access.grant(
              runtime.access,
              mutation.username,
              mutation.topic,
              permission,
            )
          {
            Ok(_) -> success()
            Error(access.InvalidTopicPattern) ->
              invalid_request(40_024, "invalid request: topic pattern invalid")
            Error(_) -> unavailable("identity storage unavailable")
          }
      }
  }
}

fn users_access_delete(
  request: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  use mutation <- parse_json(request, access_mutation_decoder())
  case access.revoke_grant(runtime.access, mutation.username, mutation.topic) {
    Ok(_) -> success()
    Error(_) -> unavailable("identity storage unavailable")
  }
}

fn with_user(
  request: Request(BitArray),
  runtime: Runtime,
  mutation: Bool,
  continue: fn(String) -> Response(BitArray),
) -> Response(BitArray) {
  let runtime.Clock(now) = runtime.clock
  case auth.authenticate(request, runtime.access, now()) {
    Ok(acl.Authenticated(username, _)) ->
      case mutation && auth.uses_session(request) && !auth.valid_csrf(request) {
        True -> forbidden()
        False -> continue(username)
      }
    Ok(acl.Anonymous)
    | Error(auth.Unauthenticated)
    | Error(auth.MalformedCredentials) -> unauthorized()
    Error(auth.SetupRequired) -> unavailable("server setup is required")
    Error(_) -> unavailable("authorization unavailable")
  }
}

fn with_admin(
  request: Request(BitArray),
  runtime: Runtime,
  mutation: Bool,
  continue: fn() -> Response(BitArray),
) -> Response(BitArray) {
  let runtime.Clock(now) = runtime.clock
  case auth.authenticate(request, runtime.access, now()) {
    Ok(acl.Authenticated(_, acl.Admin)) ->
      case mutation && auth.uses_session(request) && !auth.valid_csrf(request) {
        True -> forbidden()
        False -> continue()
      }
    Ok(_) | Error(auth.Unauthenticated) | Error(auth.MalformedCredentials) ->
      unauthorized()
    Error(auth.SetupRequired) -> unavailable("server setup is required")
    Error(_) -> unavailable("authorization unavailable")
  }
}

fn principal_identity(principal: acl.Principal) -> #(String, String) {
  case principal {
    acl.Anonymous -> #("*", "anonymous")
    acl.Authenticated(username, acl.User) -> #(username, "user")
    acl.Authenticated(username, acl.Admin) -> #(username, "admin")
  }
}

fn token_to_delete(request: Request(body)) -> Option(String) {
  case request.get_header(request, "x-token") {
    Ok(value) if value != "" -> Some(value)
    _ ->
      case query(request, "token") {
        Some(value) if value != "" -> Some(value)
        _ ->
          case auth.credentials(request) {
            Ok(access.Bearer(value)) -> Some(value)
            _ -> None
          }
      }
  }
}

fn user_json(user: identity.User, grants: List(acl.Rule)) -> json.Json {
  let user_grants =
    grants
    |> list.filter(fn(rule) { rule.username == user.username })
    |> list.map(fn(rule) {
      json.object([
        #("topic", json.string(rule.topic_pattern)),
        #("permission", json.string(permission_string(rule.permission))),
      ])
    })
  json.object([
    #("username", json.string(user.username)),
    #(
      "role",
      json.string(case user.role {
        acl.User -> "user"
        acl.Admin -> "admin"
      }),
    ),
    #("grants", json.array(user_grants, fn(value) { value })),
  ])
}

fn stored_token_json(stored: identity.Token) -> json.Json {
  json.object([
    #("token", json.string(stored.prefix)),
    #("label", json.string(stored.label)),
    #("expires", json.nullable(stored.expires, json.int)),
  ])
}

fn issued_token_json(raw: String, stored: identity.Token) -> json.Json {
  json.object([
    #("token", json.string(raw)),
    #("label", json.string(stored.label)),
    #("expires", json.nullable(stored.expires, json.int)),
  ])
}

fn user_mutation_decoder() -> decode.Decoder(UserMutation) {
  use username <- decode.field("username", decode.string)
  use password <- decode.optional_field("password", "", decode.string)
  use password_hash <- decode.optional_field("hash", "", decode.string)
  use tier <- decode.optional_field("tier", "", decode.string)
  decode.success(UserMutation(username:, password:, password_hash:, tier:))
}

fn user_delete_decoder() -> decode.Decoder(UserDelete) {
  use username <- decode.field("username", decode.string)
  decode.success(UserDelete(username:))
}

fn access_mutation_decoder() -> decode.Decoder(AccessMutation) {
  use username <- decode.field("username", decode.string)
  use topic <- decode.field("topic", decode.string)
  use permission <- decode.optional_field("permission", "", decode.string)
  decode.success(AccessMutation(username:, topic:, permission:))
}

fn password_decoder() -> decode.Decoder(PasswordMutation) {
  use password <- decode.field("password", decode.string)
  use new_password <- decode.field("new_password", decode.string)
  decode.success(PasswordMutation(password:, new_password:))
}

fn account_delete_decoder() -> decode.Decoder(AccountDelete) {
  use password <- decode.field("password", decode.string)
  decode.success(AccountDelete(password:))
}

fn token_issue_decoder() -> decode.Decoder(TokenIssue) {
  use label <- decode.optional_field("label", "", decode.string)
  use expires <- decode.optional_field(
    "expires",
    None,
    decode.optional(decode.int),
  )
  decode.success(TokenIssue(label:, expires:))
}

fn parse_permission(value: String) -> Result(acl.Permission, Nil) {
  case string.lowercase(value) {
    "read-write" | "rw" -> Ok(acl.ReadWrite)
    "read-only" | "read" | "ro" -> Ok(acl.ReadOnly)
    "write-only" | "write" | "wo" -> Ok(acl.WriteOnly)
    "deny-all" | "deny" | "none" -> Ok(acl.Deny)
    _ -> Error(Nil)
  }
}

fn permission_string(permission: acl.Permission) -> String {
  case permission {
    acl.ReadWrite -> "read-write"
    acl.ReadOnly -> "read-only"
    acl.WriteOnly -> "write-only"
    acl.Deny -> "deny-all"
  }
}

fn parse_json(
  request: Request(BitArray),
  decoder: decode.Decoder(value),
  continue: fn(value) -> Response(BitArray),
) -> Response(BitArray) {
  case bit_array.to_string(request.body) {
    Error(_) -> invalid_json()
    Ok(body) ->
      case json.parse(body, decoder) {
        Ok(value) -> continue(value)
        Error(_) -> invalid_json()
      }
  }
}

fn parse_optional_json(
  request: Request(BitArray),
  decoder: decode.Decoder(value),
  continue: fn(value) -> Response(BitArray),
) -> Response(BitArray) {
  case bit_array.to_string(request.body) {
    Error(_) -> invalid_json()
    Ok(body) ->
      case string.trim(body) {
        "" ->
          case json.parse("{}", decoder) {
            Ok(value) -> continue(value)
            Error(_) -> invalid_json()
          }
        body ->
          case json.parse(body, decoder) {
            Ok(value) -> continue(value)
            Error(_) -> invalid_json()
          }
      }
  }
}

fn option_or(value: Option(value), fallback: Option(value)) -> Option(value) {
  case value {
    Some(_) -> value
    None -> fallback
  }
}

fn query(request: Request(body), name: String) -> Option(String) {
  request.get_query(request)
  |> result.unwrap([])
  |> list.find_map(fn(pair) {
    case string.lowercase(pair.0) == name {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
  |> option_from_result
}

fn option_from_result(value: Result(value, Nil)) -> Option(value) {
  case value {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn success() -> Response(BitArray) {
  json_response(200, json.object([#("success", json.bool(True))]))
}

fn invalid_json() -> Response(BitArray) {
  invalid_request(40_024, "invalid request: request body must be valid JSON")
}

fn invalid_request(code: Int, detail: String) -> Response(BitArray) {
  ntfy_error(400, code, detail, "")
}

fn unauthorized() -> Response(BitArray) {
  ntfy_error(401, 40_101, "unauthorized", auth_docs)
}

fn forbidden() -> Response(BitArray) {
  ntfy_error(403, 40_301, "forbidden", auth_docs)
}

fn unavailable(detail: String) -> Response(BitArray) {
  ntfy_error(503, 50_301, detail, "")
}

fn ntfy_error(
  status: Int,
  code: Int,
  detail: String,
  link: String,
) -> Response(BitArray) {
  let fields = [
    #("code", json.int(code)),
    #("http", json.int(status)),
    #("error", json.string(detail)),
  ]
  let fields = case link {
    "" -> fields
    link -> list.append(fields, [#("link", json.string(link))])
  }
  json_response(status, json.object(fields))
}

fn json_response(status: Int, body: json.Json) -> Response(BitArray) {
  response.new(status)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_header("cache-control", "no-store")
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_header("access-control-allow-origin", "*")
  |> response.set_body(body |> json.to_string |> bit_array.from_string)
}
