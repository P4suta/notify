import gleam/bit_array
import gleam/dynamic/decode
import gleam/http.{Delete, Get, Post, Put}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string
import notify/access
import notify/attachment_store
import notify/core/acl
import notify/delivery
import notify/http/auth
import notify/identity
import notify/runtime.{type Runtime}
import notify/security/token

type LoginRequest {
  LoginRequest(username: String, password: String)
}

type UserRequest {
  UserRequest(username: String, password: String, role: acl.Role)
}

type PasswordRequest {
  PasswordRequest(password: String)
}

type TokenRequest {
  TokenRequest(username: String, label: String, expires: Option(Int))
}

type GrantRequest {
  GrantRequest(
    username: String,
    topic_pattern: String,
    permission: acl.Permission,
  )
}

pub fn route(
  req: Request(BitArray),
  runtime: Runtime,
) -> Option(Response(BitArray)) {
  case req.method, request.path_segments(req) {
    Post, ["api", "v1", "session"] -> Some(login(req, runtime))
    Get, ["api", "v1", "session"] -> Some(current_session(req, runtime))
    Delete, ["api", "v1", "session"] -> Some(logout(req, runtime))
    Get, ["api", "v1", "users"] ->
      Some(with_admin(req, runtime, False, fn(_) { list_users(req, runtime) }))
    Post, ["api", "v1", "users"] ->
      Some(with_admin(req, runtime, True, fn(_) { create_user(req, runtime) }))
    Delete, ["api", "v1", "users", username] ->
      Some(
        with_admin(req, runtime, True, fn(_) { delete_user(username, runtime) }),
      )
    Put, ["api", "v1", "users", username, "password"] ->
      Some(
        with_admin(req, runtime, True, fn(_) {
          change_password(req, username, runtime)
        }),
      )
    Get, ["api", "v1", "tokens"] ->
      Some(with_admin(req, runtime, False, fn(_) { list_tokens(req, runtime) }))
    Post, ["api", "v1", "tokens"] ->
      Some(with_admin(req, runtime, True, fn(_) { create_token(req, runtime) }))
    Delete, ["api", "v1", "tokens", id] ->
      Some(with_admin(req, runtime, True, fn(_) { revoke_token(id, runtime) }))
    Get, ["api", "v1", "acl"] ->
      Some(with_admin(req, runtime, False, fn(_) { list_acl(req, runtime) }))
    Put, ["api", "v1", "acl"] | Post, ["api", "v1", "acl"] ->
      Some(with_admin(req, runtime, True, fn(_) { put_acl(req, runtime) }))
    Delete, ["api", "v1", "acl"] ->
      Some(with_admin(req, runtime, True, fn(_) { delete_acl(req, runtime) }))
    Get, ["api", "v1", "anonymous-access"] ->
      Some(
        with_admin(req, runtime, False, fn(_) { get_anonymous_access(runtime) }),
      )
    Put, ["api", "v1", "anonymous-access"] ->
      Some(
        with_admin(req, runtime, True, fn(_) {
          put_anonymous_access(req, runtime)
        }),
      )
    Get, ["api", "v1", "system", "health"] ->
      Some(with_admin(req, runtime, False, fn(_) { system_health(runtime) }))
    Get, ["api", "v1", "delivery-jobs"] ->
      Some(
        with_admin(req, runtime, False, fn(_) {
          list_delivery_jobs(req, runtime)
        }),
      )
    Post, ["api", "v1", "delivery-jobs", id, "retry"] ->
      Some(
        with_admin(req, runtime, True, fn(_) { retry_delivery_job(id, runtime) }),
      )
    Delete, ["api", "v1", "delivery-jobs", id] ->
      Some(
        with_admin(req, runtime, True, fn(_) { purge_delivery_job(id, runtime) }),
      )
    Get, ["api", "v1", "attachments"] ->
      Some(
        with_admin(req, runtime, False, fn(_) { list_attachments(req, runtime) }),
      )
    Delete, ["api", "v1", "attachments", key] ->
      Some(
        with_admin(req, runtime, True, fn(_) { delete_attachment(key, runtime) }),
      )
    _, _ -> None
  }
}

fn login(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  use login <- parse_json_body(req, login_decoder())
  let runtime.Clock(now) = runtime.clock
  case
    access.setup_required(runtime.access),
    access.authenticate(
      runtime.access,
      access.Basic(login.username, login.password),
      now(),
    )
  {
    Ok(True), _ ->
      problem(503, "Setup required", "Complete the one-time server setup first")
    _, Error(_) ->
      problem(401, "Authentication failed", "Invalid username or password")
    Error(_), _ ->
      problem(
        503,
        "Authentication unavailable",
        "Identity storage is unavailable",
      )
    Ok(False), Ok(principal) -> {
      let runtime.IdGenerator(next_id) = runtime.ids
      case
        access.create_token_for_username(
          runtime.access,
          "ses_" <> next_id(),
          login.username,
          "__web_session__",
          Some(now() + 43_200),
          now(),
          token.secure_entropy,
        )
      {
        Error(_) ->
          problem(503, "Session unavailable", "Could not persist the session")
        Ok(#(_, raw)) -> {
          let #(username, role) = principal_name_role(principal)
          json_response(
            201,
            json.object([
              #("username", json.string(username)),
              #("role", json.string(role_string(role))),
              #("csrf_token", json.string(csrf_token(raw))),
              #("expires", json.int(now() + 43_200)),
            ]),
          )
          |> response.set_header(
            "set-cookie",
            "notify_session="
              <> raw
              <> "; Path=/; Max-Age=43200; Secure; HttpOnly; SameSite=Strict",
          )
        }
      }
    }
  }
}

fn current_session(
  req: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  let runtime.Clock(now) = runtime.clock
  case auth.authenticate(req, runtime.access, now()) {
    Ok(acl.Authenticated(username, role)) -> {
      let csrf = case auth.session_token(req) {
        Some(raw) -> csrf_token(raw)
        None -> ""
      }
      json_response(
        200,
        json.object([
          #("username", json.string(username)),
          #("role", json.string(role_string(role))),
          #("csrf_token", json.string(csrf)),
        ]),
      )
    }
    Ok(acl.Anonymous) | Error(auth.Unauthenticated) ->
      problem(401, "Authentication required", "Sign in to continue")
    Error(auth.SetupRequired) ->
      problem(503, "Setup required", "Complete server setup first")
    Error(_) ->
      problem(
        503,
        "Authentication unavailable",
        "Identity storage is unavailable",
      )
  }
}

fn logout(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  case auth.session_token(req), auth.valid_csrf(req) {
    None, _ ->
      problem(401, "Session required", "No web session cookie was sent")
    Some(_), False ->
      problem(403, "CSRF check failed", "Send the session CSRF token")
    Some(raw), True ->
      case access.revoke_raw_token(runtime.access, raw) {
        Error(_) ->
          problem(503, "Logout unavailable", "Could not revoke the session")
        Ok(_) ->
          response.new(204)
          |> response.set_header(
            "set-cookie",
            "notify_session=; Path=/; Max-Age=0; Secure; HttpOnly; SameSite=Strict",
          )
          |> response.set_body(<<>>)
      }
  }
}

fn with_admin(
  req: Request(BitArray),
  runtime: Runtime,
  mutation: Bool,
  next: fn(String) -> Response(BitArray),
) -> Response(BitArray) {
  let runtime.Clock(now) = runtime.clock
  case auth.authenticate(req, runtime.access, now()) {
    Ok(acl.Authenticated(username, acl.Admin)) ->
      case mutation && auth.uses_session(req) && !auth.valid_csrf(req) {
        True -> problem(403, "CSRF check failed", "Send the session CSRF token")
        False -> next(username)
      }
    Ok(_) | Error(auth.Unauthenticated) | Error(auth.MalformedCredentials) ->
      problem(
        401,
        "Administrator authentication required",
        "Sign in as an administrator",
      )
    Error(auth.SetupRequired) ->
      problem(503, "Setup required", "Complete server setup first")
    Error(_) ->
      problem(
        503,
        "Authorization unavailable",
        "Identity storage is unavailable",
      )
  }
}

fn list_users(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  case access.list_users(runtime.access) {
    Error(_) -> problem(503, "Users unavailable", "Could not list users")
    Ok(users) -> {
      let limit = page_limit(req)
      let after = query(req, "cursor")
      let selected = case after {
        None -> users
        Some(cursor) ->
          list.filter(users, fn(user) {
            string.compare(user.username, cursor) == order.Gt
          })
      }
      let page = list.take(selected, limit)
      let next_cursor = case list.length(selected) > limit {
        False -> None
        True ->
          page
          |> list.last
          |> result.map(fn(user) { user.username })
          |> option_from_result
      }
      page_response(page, next_cursor, user_json)
    }
  }
}

fn create_user(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  use new_user <- parse_json_body(req, user_decoder())
  let runtime.Clock(now) = runtime.clock
  let runtime.IdGenerator(next_id) = runtime.ids
  case
    access.add_user(
      runtime.access,
      "u_" <> next_id(),
      new_user.username,
      new_user.password,
      new_user.role,
      now(),
    )
  {
    Ok(user) -> json_response(201, user_json(user))
    Error(access.InvalidUsername) ->
      problem(400, "Invalid username", "Use 1-64 safe username characters")
    Error(access.PasswordError(_)) ->
      problem(400, "Invalid password", "Password must be 12-1024 characters")
    Error(access.IdentityError(identity.Conflict(_))) ->
      problem(409, "Username already exists", "Choose a different username")
    Error(_) ->
      problem(503, "User creation unavailable", "Could not persist the user")
  }
}

fn delete_user(username: String, runtime: Runtime) -> Response(BitArray) {
  case access.delete_user(runtime.access, username) {
    Ok(_) ->
      case runtime.webpush {
        None -> no_content()
        Some(configured) ->
          case configured.store.remove_user(username) {
            Ok(_) -> no_content()
            Error(_) ->
              problem(
                503,
                "Web Push cleanup unavailable",
                "The user was deleted, but their push subscriptions could not be removed",
              )
          }
      }
    Error(access.LastAdmin) ->
      problem(
        409,
        "Last administrator",
        "Create another administrator before deleting this user",
      )
    Error(access.IdentityError(identity.NotFound)) ->
      problem(404, "User not found", "No user has that username")
    Error(_) ->
      problem(503, "User deletion unavailable", "Could not delete the user")
  }
}

fn change_password(
  req: Request(BitArray),
  username: String,
  runtime: Runtime,
) -> Response(BitArray) {
  use password <- parse_json_body(req, password_decoder())
  case access.change_password(runtime.access, username, password.password) {
    Ok(_) -> no_content()
    Error(access.PasswordError(_)) ->
      problem(400, "Invalid password", "Password must be 12-1024 characters")
    Error(access.IdentityError(identity.NotFound)) ->
      problem(404, "User not found", "No user has that username")
    Error(_) ->
      problem(
        503,
        "Password update unavailable",
        "Could not update the password",
      )
  }
}

fn list_tokens(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  case query(req, "username") {
    None -> problem(400, "Username required", "Pass ?username=<name>")
    Some(username) ->
      case access.list_tokens(runtime.access, username) {
        Ok(tokens) -> page_response(tokens, None, stored_token_json)
        Error(access.IdentityError(identity.NotFound)) ->
          problem(404, "User not found", "No user has that username")
        Error(_) -> problem(503, "Tokens unavailable", "Could not list tokens")
      }
  }
}

fn create_token(
  req: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  use requested <- parse_json_body(req, token_decoder())
  let runtime.Clock(now) = runtime.clock
  let runtime.IdGenerator(next_id) = runtime.ids
  case
    access.create_token_for_username(
      runtime.access,
      "tok_" <> next_id(),
      requested.username,
      requested.label,
      requested.expires,
      now(),
      token.secure_entropy,
    )
  {
    Ok(#(stored, raw)) ->
      json_response(
        201,
        json.object([
          #("id", json.string(stored.id)),
          #("username", json.string(requested.username)),
          #("label", json.string(stored.label)),
          #("token", json.string(raw)),
          #("prefix", json.string(stored.prefix)),
          #("created_at", json.int(stored.created_at)),
          #("expires", json.nullable(stored.expires, json.int)),
          #("last_access", json.nullable(stored.last_access, json.int)),
        ]),
      )
    Error(access.InvalidTokenLabel) ->
      problem(
        400,
        "Invalid token label",
        "Token labels may be at most 64 characters",
      )
    Error(access.IdentityError(identity.NotFound)) ->
      problem(404, "User not found", "No user has that username")
    Error(_) -> problem(503, "Token unavailable", "Could not create the token")
  }
}

fn revoke_token(id: String, runtime: Runtime) -> Response(BitArray) {
  case access.revoke_token(runtime.access, id) {
    Ok(_) -> no_content()
    Error(_) ->
      problem(503, "Token revocation unavailable", "Could not revoke the token")
  }
}

fn list_acl(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  case access.list_grants(runtime.access, query(req, "username")) {
    Ok(rules) -> page_response(rules, None, rule_json)
    Error(_) -> problem(503, "ACL unavailable", "Could not list access rules")
  }
}

fn put_acl(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  use grant <- parse_json_body(req, grant_decoder())
  case
    access.grant(
      runtime.access,
      grant.username,
      grant.topic_pattern,
      grant.permission,
    )
  {
    Ok(rule) -> json_response(200, rule_json(rule))
    Error(access.InvalidUsername) | Error(access.InvalidTopicPattern) ->
      problem(
        400,
        "Invalid access rule",
        "Check the username and topic pattern",
      )
    Error(_) ->
      problem(503, "ACL unavailable", "Could not persist the access rule")
  }
}

fn delete_acl(req: Request(BitArray), runtime: Runtime) -> Response(BitArray) {
  use grant <- parse_json_body(req, grant_decoder())
  case
    access.revoke_grant(runtime.access, grant.username, grant.topic_pattern)
  {
    Ok(_) -> no_content()
    Error(_) ->
      problem(503, "ACL unavailable", "Could not revoke the access rule")
  }
}

fn get_anonymous_access(runtime: Runtime) -> Response(BitArray) {
  case access.default_access(runtime.access) {
    Ok(permission) ->
      json_response(
        200,
        json.object([
          #("permission", json.string(permission_string(permission))),
        ]),
      )
    Error(_) ->
      problem(503, "Policy unavailable", "Could not load the anonymous policy")
  }
}

fn put_anonymous_access(
  req: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  use grant <- parse_json_body(req, permission_request_decoder())
  case access.set_default_access(runtime.access, grant.permission) {
    Ok(permission) ->
      json_response(
        200,
        json.object([
          #("permission", json.string(permission_string(permission))),
        ]),
      )
    Error(_) ->
      problem(
        503,
        "Policy unavailable",
        "Could not update the anonymous policy",
      )
  }
}

fn system_health(runtime: Runtime) -> Response(BitArray) {
  let storage_ok = runtime.storage.health() |> result.is_ok
  let attachment_ok = case runtime.attachments {
    None -> True
    Some(store) -> store.health() |> result.is_ok
  }
  let delivery_ok = case runtime.deliveries {
    None -> True
    Some(store) -> store.health() |> result.is_ok
  }
  let webpush_ok = case runtime.webpush {
    None -> True
    Some(configured) -> configured.store.health() |> result.is_ok
  }
  let healthy = storage_ok && attachment_ok && delivery_ok && webpush_ok
  json_response(
    case healthy {
      True -> 200
      False -> 503
    },
    json.object([
      #("healthy", json.bool(healthy)),
      #(
        "storage",
        json.string(case storage_ok {
          True -> "healthy"
          False -> "unavailable"
        }),
      ),
      #(
        "attachments",
        json.string(case attachment_ok {
          True -> "healthy"
          False -> "unavailable"
        }),
      ),
      #(
        "delivery_outbox",
        json.string(case delivery_ok {
          True -> "healthy"
          False -> "unavailable"
        }),
      ),
      #(
        "web_push",
        json.string(case webpush_ok {
          True -> "healthy"
          False -> "unavailable"
        }),
      ),
      #(
        "mobile_relay",
        json.string(case runtime.relay {
          None -> "disabled"
          Some(_) -> "configured"
        }),
      ),
      #("compatibility", json.string("ntfy v2.27.0")),
    ]),
  )
}

fn list_delivery_jobs(
  req: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  case runtime.deliveries {
    None -> page_response([], None, delivery_job_json)
    Some(store) -> {
      let selected = case query(req, "kind") {
        Some("webpush") -> store.list(delivery.WebPush)
        Some("mobile_relay") | Some("relay") -> store.list(delivery.MobileRelay)
        Some(_) -> Error(delivery.NotFound)
        None ->
          case store.list(delivery.WebPush), store.list(delivery.MobileRelay) {
            Ok(webpush), Ok(relay) -> Ok(list.append(webpush, relay))
            Error(error), _ | _, Error(error) -> Error(error)
          }
      }
      case selected {
        Ok(jobs) -> page_response(jobs, None, delivery_job_json)
        Error(delivery.NotFound) ->
          problem(400, "Invalid delivery kind", "Use webpush or mobile_relay")
        Error(_) ->
          problem(
            503,
            "Delivery outbox unavailable",
            "Could not list durable delivery jobs",
          )
      }
    }
  }
}

fn delivery_job_json(job: delivery.Job) -> json.Json {
  json.object([
    #("id", json.string(job.id)),
    #("kind", json.string(delivery_kind_string(job.kind))),
    #("message_id", json.string(job.message_id)),
    #("topic_hash", json.string(job.topic_hash)),
    #("state", json.string(delivery_state_string(job.state))),
    #("attempts", json.int(job.attempts)),
    #("available_at", json.int(job.available_at)),
    #("lease_owner", json.nullable(job.lease_owner, json.string)),
    #("lease_until", json.nullable(job.lease_until, json.int)),
    #("last_error", json.nullable(job.last_error, json.string)),
  ])
}

fn retry_delivery_job(id: String, runtime: Runtime) -> Response(BitArray) {
  case runtime.deliveries {
    None ->
      problem(404, "Delivery job not found", "The delivery outbox is disabled")
    Some(store) -> {
      let runtime.Clock(now) = runtime.clock
      case store.requeue(id, now()) {
        Ok(job) -> json_response(200, delivery_job_json(job))
        Error(delivery.NotFound) ->
          problem(404, "Delivery job not found", "No job has that ID")
        Error(delivery.Conflict) ->
          problem(
            409,
            "Delivery job is active",
            "Only dead-letter jobs can be retried manually",
          )
        Error(_) ->
          problem(
            503,
            "Delivery retry unavailable",
            "Could not requeue the delivery job",
          )
      }
    }
  }
}

fn purge_delivery_job(id: String, runtime: Runtime) -> Response(BitArray) {
  case runtime.deliveries {
    None ->
      problem(404, "Delivery job not found", "The delivery outbox is disabled")
    Some(store) ->
      case store.purge(id) {
        Ok(_) -> no_content()
        Error(delivery.NotFound) ->
          problem(404, "Delivery job not found", "No job has that ID")
        Error(delivery.Conflict) ->
          problem(
            409,
            "Delivery job is active",
            "Only dead-letter jobs can be purged manually",
          )
        Error(_) ->
          problem(
            503,
            "Delivery purge unavailable",
            "Could not purge the delivery job",
          )
      }
  }
}

fn delivery_kind_string(kind: delivery.Kind) -> String {
  case kind {
    delivery.WebPush -> "webpush"
    delivery.MobileRelay -> "mobile_relay"
  }
}

fn delivery_state_string(state: delivery.State) -> String {
  case state {
    delivery.Pending -> "pending"
    delivery.Leased -> "leased"
    delivery.DeadLetter -> "dead_letter"
  }
}

fn list_attachments(
  req: Request(BitArray),
  runtime: Runtime,
) -> Response(BitArray) {
  case runtime.attachments {
    None -> page_response([], None, attachment_json)
    Some(store) ->
      case store.list() {
        Error(_) ->
          problem(
            503,
            "Attachments unavailable",
            "Could not list attachment metadata",
          )
        Ok(items) -> {
          let limit = page_limit(req)
          let selected = case query(req, "cursor") {
            None -> items
            Some(cursor) ->
              list.filter(items, fn(item) {
                string.compare(item.key, cursor) == order.Gt
              })
          }
          let page = list.take(selected, limit)
          let next_cursor = case list.length(selected) > limit {
            False -> None
            True ->
              page
              |> list.last
              |> result.map(fn(item) { item.key })
              |> option_from_result
          }
          page_response(page, next_cursor, attachment_json)
        }
      }
  }
}

fn delete_attachment(key: String, runtime: Runtime) -> Response(BitArray) {
  case runtime.attachments {
    None -> problem(404, "Attachment not found", "Attachments are disabled")
    Some(store) ->
      case store.head(key) {
        Error(attachment_store.NotFound) ->
          problem(404, "Attachment not found", "No attachment has that key")
        Error(_) ->
          problem(
            503,
            "Attachments unavailable",
            "Could not inspect the attachment",
          )
        Ok(_) ->
          case store.delete(key) {
            Ok(_) -> no_content()
            Error(_) ->
              problem(
                503,
                "Attachment deletion unavailable",
                "Could not delete the attachment",
              )
          }
      }
  }
}

fn attachment_json(stored: attachment_store.Stored) -> json.Json {
  json.object([
    #("key", json.string(stored.key)),
    #("size", json.int(stored.size)),
    #("expires", json.int(stored.expires)),
  ])
}

fn login_decoder() -> decode.Decoder(LoginRequest) {
  use username <- decode.field("username", decode.string)
  use password <- decode.field("password", decode.string)
  decode.success(LoginRequest(username:, password:))
}

fn user_decoder() -> decode.Decoder(UserRequest) {
  use username <- decode.field("username", decode.string)
  use password <- decode.field("password", decode.string)
  use role <- decode.optional_field("role", acl.User, role_decoder())
  decode.success(UserRequest(username:, password:, role:))
}

fn password_decoder() -> decode.Decoder(PasswordRequest) {
  use password <- decode.field("password", decode.string)
  decode.success(PasswordRequest(password:))
}

fn token_decoder() -> decode.Decoder(TokenRequest) {
  use username <- decode.field("username", decode.string)
  use label <- decode.optional_field("label", "", decode.string)
  use expires <- decode.optional_field(
    "expires",
    None,
    decode.optional(decode.int),
  )
  decode.success(TokenRequest(username:, label:, expires:))
}

fn grant_decoder() -> decode.Decoder(GrantRequest) {
  use username <- decode.field("username", decode.string)
  use topic_pattern <- decode.field("topic_pattern", decode.string)
  use permission <- decode.field("permission", permission_decoder())
  decode.success(GrantRequest(username:, topic_pattern:, permission:))
}

fn permission_request_decoder() -> decode.Decoder(GrantRequest) {
  use permission <- decode.field("permission", permission_decoder())
  decode.success(GrantRequest(username: "*", topic_pattern: "*", permission:))
}

fn role_decoder() -> decode.Decoder(acl.Role) {
  use value <- decode.then(decode.string)
  case string.lowercase(value) {
    "admin" -> decode.success(acl.Admin)
    "user" -> decode.success(acl.User)
    _ -> decode.failure(acl.User, expected: "user or admin")
  }
}

fn permission_decoder() -> decode.Decoder(acl.Permission) {
  use value <- decode.then(decode.string)
  case string.lowercase(value) {
    "deny" | "deny-all" | "none" -> decode.success(acl.Deny)
    "read" | "read-only" | "ro" -> decode.success(acl.ReadOnly)
    "write" | "write-only" | "wo" -> decode.success(acl.WriteOnly)
    "read-write" | "rw" -> decode.success(acl.ReadWrite)
    _ -> decode.failure(acl.Deny, expected: "access permission")
  }
}

fn user_json(user: identity.User) -> json.Json {
  json.object([
    #("id", json.string(user.id)),
    #("username", json.string(user.username)),
    #("role", json.string(role_string(user.role))),
    #("created_at", json.int(user.created_at)),
  ])
}

fn stored_token_json(stored: identity.Token) -> json.Json {
  json.object([
    #("id", json.string(stored.id)),
    #("user_id", json.string(stored.user_id)),
    #("prefix", json.string(stored.prefix)),
    #("label", json.string(stored.label)),
    #("created_at", json.int(stored.created_at)),
    #("expires", json.nullable(stored.expires, json.int)),
    #("last_access", json.nullable(stored.last_access, json.int)),
  ])
}

fn rule_json(rule: acl.Rule) -> json.Json {
  json.object([
    #("username", json.string(rule.username)),
    #("topic_pattern", json.string(rule.topic_pattern)),
    #("permission", json.string(permission_string(rule.permission))),
  ])
}

fn page_response(
  items: List(a),
  next_cursor: Option(String),
  encode: fn(a) -> json.Json,
) -> Response(BitArray) {
  json_response(
    200,
    json.object([
      #("items", json.array(items, encode)),
      #("next_cursor", json.nullable(next_cursor, json.string)),
    ]),
  )
}

fn page_limit(req: Request(body)) -> Int {
  case query(req, "limit") |> option_then_int {
    Some(limit) if limit >= 1 && limit <= 100 -> limit
    _ -> 50
  }
}

fn query(req: Request(body), name: String) -> Option(String) {
  request.get_query(req)
  |> result.unwrap([])
  |> list.find_map(fn(pair) {
    case pair.0 == name {
      True -> Ok(pair.1)
      False -> Error(Nil)
    }
  })
  |> option_from_result
}

fn parse_json_body(
  req: Request(BitArray),
  decoder: decode.Decoder(a),
  continue: fn(a) -> Response(BitArray),
) -> Response(BitArray) {
  case bit_array.to_string(req.body) {
    Error(_) -> problem(400, "Invalid JSON", "Request body is not UTF-8")
    Ok(body) ->
      case json.parse(body, decoder) {
        Error(_) ->
          problem(400, "Invalid JSON", "Request fields are missing or invalid")
        Ok(value) -> continue(value)
      }
  }
}

fn principal_name_role(principal: acl.Principal) -> #(String, acl.Role) {
  case principal {
    acl.Authenticated(username, role) -> #(username, role)
    acl.Anonymous -> #("", acl.User)
  }
}

fn csrf_token(raw: String) -> String {
  token.digest("csrf:" <> raw)
}

fn role_string(role: acl.Role) -> String {
  case role {
    acl.User -> "user"
    acl.Admin -> "admin"
  }
}

fn permission_string(permission: acl.Permission) -> String {
  case permission {
    acl.Deny -> "deny"
    acl.ReadOnly -> "read"
    acl.WriteOnly -> "write"
    acl.ReadWrite -> "read-write"
  }
}

fn option_from_result(value: Result(a, Nil)) -> Option(a) {
  case value {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

fn option_then_int(value: Option(String)) -> Option(Int) {
  case value {
    Some(value) -> int.parse(value) |> option_from_result
    None -> None
  }
}

fn json_response(status: Int, body: json.Json) -> Response(BitArray) {
  response.new(status)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_header("cache-control", "no-store")
  |> response.set_header("x-content-type-options", "nosniff")
  |> response.set_body(body |> json.to_string |> bit_array.from_string)
}

fn problem(status: Int, title: String, detail: String) -> Response(BitArray) {
  json_response(
    status,
    json.object([
      #("type", json.string("about:blank")),
      #("title", json.string(title)),
      #("status", json.int(status)),
      #("detail", json.string(detail)),
    ]),
  )
  |> response.set_header(
    "content-type",
    "application/problem+json; charset=utf-8",
  )
}

fn no_content() -> Response(BitArray) {
  response.new(204)
  |> response.set_header("cache-control", "no-store")
  |> response.set_body(<<>>)
}
